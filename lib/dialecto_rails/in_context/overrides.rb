module DialectoRails
  module InContext
    # The saved-drafts payload the overlay posts to `/__dialecto/overrides` (spec-0017 §1.2):
    # `{edits: [{domain, key, locale, to}]}`, where a plural entry carries `forms: [text, …]` (in the entry's
    # categories in canonical order, matching a marker's `__form`) instead of, or beside, `to`.
    module Overrides
      MAX_EDITS = 5_000
      MAX_TEXT = 20_000
      MAX_KEY = 20_000
      MAX_FORMS = 10
      LOCALE = /\A[a-z]{2,3}([-_][A-Za-z0-9]{2,8})*\z/

      Result = Struct.new(:applied, :ignored, keyword_init: true)

      module_function

      # A Result, or nil when the payload isn't a well-formed edit list.
      def parse(payload)
        edits = payload.is_a?(Hash) ? payload["edits"] : nil
        return nil unless edits.is_a?(Array) && edits.length <= MAX_EDITS

        applied = []
        ignored = 0
        edits.each do |edit|
          case (entry = edit_entry(edit))
          when :error then return nil
          when :ignored then ignored += 1
          else applied << entry
          end
        end
        Result.new(applied: applied, ignored: ignored)
      end

      def edit_entry(edit)
        return :error unless edit.is_a?(Hash)

        domain, key, locale = edit.values_at("domain", "key", "locale")
        return :error unless [domain, key, locale].all?(String)
        return :error unless domain.length <= 512 && !key.empty? && key.length <= MAX_KEY && locale.length <= 64

        override = override_for(edit["to"], edit["forms"])
        return :error unless override

        locale.match?(LOCALE) ? {domain: domain, key: key, locale: locale, override: override} : :ignored
      end

      def override_for(to, forms)
        return nil unless to.nil? || (to.is_a?(String) && to.length <= MAX_TEXT)
        return nil unless forms.nil? || forms?(forms)
        return nil if to.nil? && forms.nil?

        {to: to, forms: forms}.compact
      end

      def forms?(forms)
        forms.is_a?(Array) && !forms.empty? && forms.length <= MAX_FORMS &&
          forms.all? { |form| form.is_a?(String) && form.length <= MAX_TEXT }
      end
    end
  end
end
