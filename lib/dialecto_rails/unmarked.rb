module DialectoRails
  # The per-request flag of live-site editing. It lives in the execution state of the thread (or fiber) that
  # renders the page, so jobs and other threads never inherit it. It is here, outside `InContext`, because app
  # code calls `DialectoRails.unmarked` and a process that never turns live mode on must not load any of the
  # in-context machinery to do so.
  LIVE_MARKING = :dialecto_live_marking

  class << self
    # True while this thread renders a page for an editor.
    def live_marking?
      state = execution_state
      !state.nil? && state[LIVE_MARKING] == true
    end

    # Runs the block with live-site markers off and restores the flag after, even on a raise. Wrap whatever
    # renders text that leaves the page, such as a mail sent while an editor's request is being handled.
    def unmarked
      state = execution_state
      return yield unless state

      previous = state[LIVE_MARKING]
      state[LIVE_MARKING] = false
      begin
        yield
      ensure
        state[LIVE_MARKING] = previous
      end
    end

    # The middleware's side of the flag.
    def live_marking=(on)
      state = execution_state
      state[LIVE_MARKING] = on if state
    end

    private

    def execution_state
      defined?(::ActiveSupport::IsolatedExecutionState) ? ::ActiveSupport::IsolatedExecutionState : nil
    end
  end
end
