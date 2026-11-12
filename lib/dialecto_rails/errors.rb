module DialectoRails
  # An expected failure: the CLI prints the message and exits with `exit_code`, never a stack trace.
  class Error < StandardError
    def exit_code = 2
  end

  # The command can't start: missing token or project, a bad URL, not a git repository, a limit.
  class ConfigError < Error
    def exit_code = 2
  end

  # The server refused and a retry can't help (401, 403, 413, 422).
  class RefusedError < Error
    def exit_code = 3
  end

  # Still failing after the retries: 429, 5xx, a timeout, a refused or reset connection.
  class RetryableError < Error
    def exit_code = 4
  end
end
