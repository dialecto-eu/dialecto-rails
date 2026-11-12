module DialectoRails
  module InContext
    # The dev server's in-context state: whether marking is on (spec-0017 §1.3) and the saved drafts the
    # overlay sent (§1.2). Marking lasts `MARKING_TTL_MS` after the last `set_marking(true)`: the overlay
    # heartbeats while the editor is open, so a closed tab or a crashed overlay can't leave markers on.
    class Store
      MARKING_TTL_MS = 90_000

      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) })
        @clock = clock
        @mutex = Mutex.new
        @marking_until = nil
        @overrides = {}.freeze
      end

      def marking_ttl_ms = MARKING_TTL_MS

      def marking?
        until_ms = @marking_until
        !until_ms.nil? && until_ms > @clock.call
      end

      def set_marking(on, ttl_ms = MARKING_TTL_MS)
        @mutex.synchronize { @marking_until = on ? @clock.call + ttl_ms : nil }
        on
      end

      # The draft for `{domain, key, locale}`, or nil: `{to: String}` and/or `{forms: [String]}`.
      def override(domain, key, locale) = @overrides[[domain, key, locale]]

      def overrides? = !@overrides.empty?

      # Replaces every draft: the overlay always sends the full set, so an empty list restores the catalogs.
      def replace_overrides(entries)
        table = entries.to_h { |entry| [[entry[:domain], entry[:key], entry[:locale]], entry[:override]] }.freeze
        @mutex.synchronize { @overrides = table }
        nil
      end
    end
  end
end
