require "json"
require "net/http"
require "openssl"
require "uri"

module DialectoRails
  module Scan
    # Talks to a Dialecto server under the project's scan token (docs/ingestion-api.md). Expected failures
    # are `RefusedError` (fix the pipeline) or `RetryableError` (wait and rerun); the token never appears
    # in a message.
    class Client
      Response = Struct.new(:status, :body, keyword_init: true)

      RETRY_DELAYS = [1, 4, 16].freeze
      MAX_RETRY_AFTER = 60
      NETWORK_ERRORS = [
        Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
        Errno::EPIPE, SocketError, EOFError, OpenSSL::SSL::SSLError
      ].freeze

      def initialize(config, sleeper: Kernel.method(:sleep), jitter: -> { rand * 0.25 }, log: nil)
        @config = config
        @sleeper = sleeper
        @jitter = jitter
        @log = log
      end

      # `{scan_mode, branch_regex, tracked_branches}`.
      def scan_config
        JSON.parse(request(Net::HTTP::Get, "scan-config", nil).body)
      rescue JSON::ParserError
        raise RetryableError, "Dialecto's scan-config answer isn't JSON; try again in a moment."
      end

      # The server's answer to a scan: `{"scan_id", "outcome", "counts"?, "skipped"}`, with the HTTP status.
      def post_scan(body)
        response = request(Net::HTTP::Post, "scans", body)
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          {}
        end
        parsed.merge("status" => response.status)
      end

      private

      def request(klass, tail, body)
        uri = URI.parse("#{@config.url}/api/repos/#{@config.project}/#{tail}")
        attempts = 0
        loop do
          result = attempt(klass, uri, body)
          return result if result.is_a?(Response)

          attempts += 1
          delay = RETRY_DELAYS[attempts - 1]
          raise RetryableError, result if delay.nil?

          wait = [delay, @retry_after.to_i].max + @jitter.call
          @retry_after = nil
          @log&.call("Dialecto answered #{result}; retrying in #{wait.round(1)}s (#{attempts}/#{RETRY_DELAYS.length})")
          @sleeper.call(wait)
        end
      end

      # A Response when the server gave a final answer; otherwise a String saying why it can be retried.
      def attempt(klass, uri, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 60
        req = klass.new(uri.request_uri)
        req["Authorization"] = "Bearer #{@config.scan_token}"
        req["Accept"] = "application/json"
        req["User-Agent"] = "dialecto-rails/#{VERSION}"
        if body
          req["Content-Type"] = "application/json"
          req.body = body
        end

        res = http.start { |connection| connection.request(req) }
        classify(res)
      rescue *NETWORK_ERRORS => e
        "a network error (#{e.class.name.split("::").last})"
      end

      def classify(res)
        status = res.code.to_i
        return Response.new(status: status, body: res.body.to_s) if status.between?(200, 299)

        # A redirect (the apex domain answers 301) is not an ingest; following it would resend the token.
        if status.between?(300, 399)
          raise RefusedError, "HTTP #{status} to #{res["location"] || "(no Location)"}: check DIALECTO_URL"
        end

        if status == 429 || status >= 500
          retry_after = res["retry-after"].to_i
          @retry_after = [retry_after, MAX_RETRY_AFTER].min if retry_after.positive?
          return "HTTP #{status}"
        end

        raise RefusedError, refusal(status, res.body.to_s)
      end

      def refusal(status, raw)
        data = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          {}
        end
        message = data["message"] || data["error"] || "HTTP #{status}"
        code = data["error"] && data["message"] ? " (#{data["error"]})" : ""
        "#{message}#{code}"
      end
    end
  end
end
