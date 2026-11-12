module DialectoRails
  module InContext
    # What `Marking` reads in live mode, in the shape of the development `Store`: marking is the rendering
    # thread's own flag (`DialectoRails.live_marking?`), never a process-wide switch, and there are no saved
    # drafts. Nothing here can be written to, so nothing a stranger sends can change a visitor's text.
    class LiveStore
      def marking? = ::DialectoRails.live_marking?

      def override(_domain, _key, _locale) = nil

      def overrides? = false
    end
  end
end
