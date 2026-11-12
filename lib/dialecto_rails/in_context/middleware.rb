require "json"
require "ipaddr"
require "cgi"
require_relative "overrides"
require_relative "../version"

module DialectoRails
  module InContext
    # The dev server's side of the in-context editor (spec-0023 §7.6; spec-0017 §1.4 for the endpoints). Pure
    # Rack, inserted at position 0, so it sees every request and every response.
    #
    # Loopback only, by two independent checks: the socket's peer (`REMOTE_ADDR`, never `X-Forwarded-For`)
    # must be a loopback address, and the `Host` must be `localhost`, `127.0.0.1` or `[::1]`, which also
    # defeats DNS rebinding. A POST must carry this site's own `Origin`; a foreign `Origin` or
    # `Sec-Fetch-Site: cross-site` is refused.
    class Middleware
      PREFIX = "/__dialecto".freeze
      MAX_BODY = 256 * 1024
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze
      LOOPBACK_NETS = [IPAddr.new("127.0.0.0/8"), IPAddr.new("::1"), IPAddr.new("::ffff:127.0.0.0/104")].freeze
      JSON_HEADERS = {"content-type" => "application/json", "cache-control" => "no-store"}.freeze

      # `settings`: url, url_valid?, project, paths (array or nil), catalogs. `store`, `git_context`: the
      # runtime's. `logger` may be nil.
      def initialize(app, settings:, store:, git_context:, logger: nil)
        @app = app
        @settings = settings
        @store = store
        @git_context = git_context
        @logger = logger
      end

      def call(env)
        path = env["PATH_INFO"].to_s
        return endpoint(env, path.delete_prefix(PREFIX)) if path == PREFIX || path.start_with?(PREFIX + "/")

        response = @app.call(env)
        document_request?(env) && path_allowed?(path) ? inject(env, response) : response
      end

      private

      ## Endpoints

      def endpoint(env, route)
        case route
        when "/context" then context(env)
        when "/overrides" then post(env) { |payload| overrides(payload) }
        when "/marking" then post(env) { |payload| marking(payload) }
        else json(404, error: "not_found")
        end
      rescue => error
        @logger&.debug("dialecto-rails: endpoint failed (#{error.class})")
        json(500, error: "internal")
      end

      def context(env)
        return json(405, error: "method_not_allowed") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])
        return json(403, error: "forbidden_origin") unless read_allowed?(env)

        json(200, @git_context.read)
      end

      def post(env)
        return json(405, error: "method_not_allowed") unless env["REQUEST_METHOD"] == "POST"
        return json(403, error: "forbidden_origin") unless write_allowed?(env)

        body = env["rack.input"]&.read(MAX_BODY + 1).to_s
        return json(413, error: "too_large") if body.bytesize > MAX_BODY

        payload = begin
          JSON.parse(body)
        rescue JSON::ParserError
          return json(400, error: "invalid_json")
        end
        status, result = yield payload
        json(status, result)
      end

      def overrides(payload)
        parsed = Overrides.parse(payload)
        return [400, {error: "invalid_edits"}] unless parsed

        @store.replace_overrides(parsed.applied)
        [200, {ok: true, applied: parsed.applied.length, ignored: parsed.ignored}]
      end

      def marking(payload)
        on = payload.is_a?(Hash) ? payload["on"] : nil
        return [400, {error: "invalid_marking"}] unless on == true || on == false

        [200, {ok: true, on: @store.set_marking(on), ttl_ms: @store.marking_ttl_ms}]
      end

      def json(status, body)
        text = JSON.generate(body)
        [status, JSON_HEADERS.merge("content-length" => text.bytesize.to_s), [text]]
      end

      ## Who may call

      def read_allowed?(env)
        loopback?(env) && origin_ok?(env, required: false) && [nil, "same-origin"].include?(env["HTTP_SEC_FETCH_SITE"])
      end

      def write_allowed?(env)
        loopback?(env) && origin_ok?(env, required: true) && env["HTTP_SEC_FETCH_SITE"] != "cross-site"
      end

      def loopback?(env) = LOOPBACK_HOSTS.include?(host(env)) && loopback_peer?(env)

      # `Host` is the client's to choose, so the peer address must be loopback too: a LAN peer of a server
      # bound to 0.0.0.0 can send `Host: localhost`.
      def loopback_peer?(env)
        address = IPAddr.new(env["REMOTE_ADDR"].to_s)
        LOOPBACK_NETS.any? { |net| net.family == address.family && net.include?(address) }
      rescue IPAddr::Error
        false
      end

      def host(env)
        value = (env["HTTP_HOST"] || env["SERVER_NAME"]).to_s.downcase
        value.start_with?("[") ? value[/\A\[[^\]]*\]/].to_s : value.sub(/:\d+\z/, "")
      end

      def origin_ok?(env, required:)
        origin = env["HTTP_ORIGIN"]
        return !required if origin.nil?

        origin == "#{env["rack.url_scheme"] || "http"}://#{env["HTTP_HOST"]}"
      end

      ## The loader

      def document_request?(env)
        env["REQUEST_METHOD"] == "GET" && @settings.url_valid? && loopback?(env) &&
          [nil, "document"].include?(env["HTTP_SEC_FETCH_DEST"]) &&
          env["HTTP_X_REQUESTED_WITH"].to_s.empty? && env["HTTP_TURBO_FRAME"].to_s.empty?
      end

      def path_allowed?(path)
        prefixes = @settings.paths
        return true if prefixes.nil?

        prefixes.any? do |prefix|
          base = prefix.chomp("/")
          path == base || path.start_with?(base + "/")
        end
      end

      def inject(env, response)
        status, headers, body = response
        return response unless html?(headers) && header(headers, "content-encoding").nil?

        html = +""
        body.each { |part| html << part.to_s }
        body.close if body.respond_to?(:close)
        html.force_encoding(Encoding::UTF_8)
        add_loader(env, status, headers, html)
      end

      # Never breaks the page: any failure here returns the buffered document as it was.
      def add_loader(env, status, headers, html)
        at = html.index("</head>")
        return [status, headers, [html]] unless at

        out = html.dup.insert(at, loader_tag(env, headers))
        headers = headers.dup
        key = headers.keys.find { |name| name.casecmp?("content-length") }
        headers[key] = out.bytesize.to_s if key
        [status, headers, [out]]
      rescue => error
        @logger&.debug("dialecto-rails: loader skipped (#{error.class})")
        [status, headers, [html]]
      end

      def html?(headers) = header(headers, "content-type").to_s.start_with?("text/html")

      def header(headers, name)
        key = headers.keys.find { |candidate| candidate.casecmp?(name) }
        key && headers[key]
      end

      def loader_tag(env, headers)
        base = "#{env["SCRIPT_NAME"]}#{PREFIX}"
        csp = header(headers, "content-security-policy").to_s + header(headers, "content-security-policy-report-only").to_s
        nonce = csp[/'nonce-([A-Za-z0-9+\/=_-]+)'/, 1]
        attributes = {
          "src" => @settings.url + "/assets/in-context/overlay.js",
          "data-url" => @settings.url,
          "data-context" => base + "/context",
          "data-overrides" => base + "/overrides",
          "data-marking" => base + "/marking",
          "data-project" => @settings.project,
          "nonce" => nonce
        }.compact.map { |name, value| %( #{name}="#{CGI.escapeHTML(value.to_s)}") }.join
        # Deferred: the page renders even when Dialecto is slow or unreachable.
        "<script defer#{attributes}></script>"
      end
    end
  end
end
