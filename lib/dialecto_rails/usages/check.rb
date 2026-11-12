module DialectoRails
  module Usages
    # `dialecto-rails check` (spec-0023 §6.8): code that reads a key the catalogs no longer hold. Runtime-only
    # keys (`pattern` `*`) are never findings.
    class Check
      Finding = Struct.new(:code, :file, :line, :message, :warning, keyword_init: true)

      # Namespaces Rails and common gems supply themselves, so a missing app catalog entry isn't a finding.
      FRAMEWORK = %w[date time datetime number helpers errors activerecord activemodel activesupport support
        views flash devise].freeze
      TEST_FILE = %r{\A(?:test|spec|features)/}

      def initialize(envelope, catalog)
        @usages = envelope["usages"]
        @catalog = catalog
      end

      def findings
        @findings ||= @usages.flat_map { |usage| inspect_usage(usage) }
      end

      def failed? = findings.any? { |finding| !finding.warning }

      private

      def inspect_usage(usage)
        case usage["kind"]
        when "static" then static(usage)
        when "set" then set(usage)
        when "pattern" then pattern(usage)
        else []
        end
      end

      def static(usage)
        key = usage["key"]
        return [] if present?(key) || framework?(key) || Array(usage["defaults"]).any? { |entry| present?(entry["key"]) }

        [finding("missing_key", usage, "reads #{key}, which no catalog has")]
      end

      def set(usage)
        keys = usage["keys"]
        return [] if keys.any? { |key| present?(key) || framework?(key) }

        [finding("missing_keys", usage, "reads one of #{keys.first(3).join(", ")}#{keys.length > 3 ? ", …" : ""}; no catalog has any")]
      end

      def pattern(usage)
        parts = usage["parts"]
        return [] unless parts.any? { |part| part.key?("lit") }
        return [] if framework?(usage["pattern"])

        regexp = Regexp.new("\\A" + parts.map { |part| part["lit"] ? Regexp.escape(part["lit"]) : ".*" }.join + "\\z")
        return [] if @catalog.keys.any? { |key| regexp.match?(key) }

        [finding("no_matching_keys", usage, "reads #{usage["pattern"]}, which matches no catalog key")]
      end

      def present?(key) = @catalog.include?(key) || @catalog.prefix?("#{key}.")

      def framework?(key) = FRAMEWORK.include?(key.to_s.split(".").first)

      def finding(code, usage, message)
        Finding.new(code: code, file: usage["file"], line: usage["start_line"], message: message,
          warning: usage["file"].match?(TEST_FILE))
      end
    end
  end
end
