module DialectoRails
  module InContext
    # Prepended on the class of the I18n backend (spec-0023 §7.4), outside `Pluralization` and `Fallbacks`, so
    # it sees the final string whichever of them ran. Never raises into the app: any failure returns the
    # unmarked result.
    #
    # In live mode `gate` answers whether this thread is rendering for an editor; while it says no, a lookup
    # takes the plain path and the hook leaves no trace.
    module BackendHook
      PLURAL = :dialecto_rails_plural

      class << self
        attr_accessor :marking, :logger, :gate

        def active? = !marking.nil? && (gate.nil? || gate.call)
      end

      def translate(locale, key, options = ::I18n::EMPTY_HASH)
        return super unless BackendHook.active?

        marking = BackendHook.marking
        Thread.current[PLURAL] = nil
        result = super
        begin
          marking.call(locale, key, options, result, Thread.current[PLURAL])
        rescue => error # standard errors only; the hook never breaks a page
          BackendHook.logger&.debug("dialecto-rails: marking skipped (#{error.class}: #{error.message})")
          result
        end
      end

      def pluralize(locale, entry, count)
        result = super
        Thread.current[PLURAL] = [entry, result] if entry.is_a?(Hash) && BackendHook.active?
        result
      end
    end
  end
end
