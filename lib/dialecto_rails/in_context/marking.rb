require "cgi"
require_relative "marker"
require_relative "args"

module DialectoRails
  module InContext
    # Turns an I18n lookup's result into a marked string (spec-0023 §7.2, §7.4, §7.5). Pure apart from the
    # store and index it is given, so it is tested without a Rails app.
    class Marking
      CATEGORIES = %i[zero one two few many other].freeze
      SKIPPED_PREFIXES = %w[date. datetime. time. number. support. i18n.].freeze
      SKIPPED_SUFFIX = /(\.(url|path|href|format)|_format)\z/

      def initialize(store:, index:, skip_keys: -> { [] }, fallbacks: nil, sanitizer: nil)
        @store = store
        @index = index
        @skip_keys = skip_keys
        @fallbacks = fallbacks || method(:i18n_fallbacks)
        @sanitizer = sanitizer
      end

      # `plural` is `[entry, chosen_text]` recorded by the pluralize wrapper, or nil.
      def call(locale, key, options, result, plural)
        return result unless @store.marking? && result.is_a?(String) && !result.start_with?(Marker::OPEN)
        return result if key.is_a?(Array) || key.nil?

        absolute = absolute_key(locale, key, options)
        return result if absolute.empty? || skipped?(absolute)

        found_locale, domain = resolve(locale, absolute)
        return result unless domain

        form, count = plural_form(options, plural)
        html = html_key?(absolute) || safe?(result)
        text = draft(domain, absolute, found_locale, options, form, html) || result
        extras = {}
        extras["__n"] = count if form
        extras["__form"] = form if form
        extras["__html"] = true if html_key?(absolute)
        marked = Marker.mark(domain, absolute, found_locale, text, Args.json(options, extras))
        safe?(result) && marked.respond_to?(:html_safe) ? marked.html_safe : marked
      end

      def absolute_key(locale, key, options)
        parts = ::I18n.normalize_keys(locale, key, options[:scope], options[:separator] || ::I18n.default_separator)
        parts.drop(1).join(".")
      end

      def skipped?(absolute)
        SKIPPED_PREFIXES.any? { |prefix| absolute.start_with?(prefix) } || absolute.match?(SKIPPED_SUFFIX) ||
          @skip_keys.call.any? { |pattern| skip_match?(pattern, absolute) }
      end

      def html_key?(absolute) = absolute.end_with?("_html") || absolute.split(".").last == "html"

      private

      # The first of the locale and its fallbacks whose files hold the key, so a page showing English
      # fallback text is marked `en`.
      def resolve(locale, absolute)
        candidates = [locale.to_s] + Array(@fallbacks.call(locale)).map(&:to_s)
        candidates.uniq.each do |candidate|
          domain = @index.domain(candidate, absolute)
          return [candidate, domain] if domain
        end
        nil
      end

      def i18n_fallbacks(locale)
        ::I18n.respond_to?(:fallbacks) ? ::I18n.fallbacks[locale] : []
      end

      # The index of the chosen category among the entry's categories in canonical order (what the sidebar
      # lists for the plural), and the count.
      def plural_form(options, plural)
        return nil unless options.key?(:count) && plural

        entry, chosen = plural
        categories = CATEGORIES.select { |category| entry.key?(category) || entry.key?(category.to_s) }
        chosen_key = entry.find { |_name, value| value.equal?(chosen) }&.first ||
          entry.find { |_name, value| value == chosen }&.first
        index = categories.index(chosen_key&.to_sym)
        index ? [index, options[:count]] : nil
      end

      # A draft is not yet reviewed, and may come from another person in the org. Where the page will treat the
      # text as HTML (an `_html` key, or a result that is already html_safe) it is sanitized after
      # interpolation, and escaped when there is no sanitizer: it fails closed.
      def draft(domain, absolute, locale, options, form, html)
        override = @store.override(domain, absolute, locale)
        return nil unless override

        template = form && override[:forms] ? override[:forms][form] : override[:to]
        template ||= override[:forms]&.first
        return nil unless template

        values = options.reject { |name, _value| Args::RESERVED.include?(name) }
        text = begin
          ::I18n.interpolate(template, values)
        rescue ::I18n::ArgumentError
          template
        end
        html ? clean_html(text) : text
      end

      def clean_html(text)
        @sanitizer ? @sanitizer.call(text).to_s : CGI.escapeHTML(text)
      rescue StandardError
        CGI.escapeHTML(text)
      end

      def safe?(result) = result.respond_to?(:html_safe?) && result.html_safe?

      def skip_match?(pattern, absolute)
        case pattern
        when Regexp then pattern.match?(absolute)
        else Regexp.new("\\A" + Regexp.escape(pattern.to_s).gsub("\\*", ".*") + "\\z").match?(absolute)
        end
      end
    end
  end
end
