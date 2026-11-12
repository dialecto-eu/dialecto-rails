require "cgi"
require "json"
require_relative "../config"
require_relative "../unmarked"
require_relative "../version"
require_relative "launch_token"
require_relative "csp"

module DialectoRails
  module InContext
    # Live-site editing for the Rack stack (spec-0025 §4): inert for visitors, on only for an editor who
    # arrived with a launch link. Insert it after the session middleware.
    #
    # * Start: a `GET` with `?dialecto_edit=<token>` is verified (signature, `start_by`, origin). A good token
    #   becomes the `dialecto_edit` cookie (`HttpOnly; Secure; SameSite=Lax; Path=/`, `Max-Age` to `exp`). Either
    #   way the answer is `303` to this request's own path and query without the parameter. The session is never
    #   touched: nothing reads a copy, and a token in a cookie-store session risks CookieOverflow.
    # * Each request: a valid cookie marks a document `GET` or `HEAD` (the thread's flag is on while the app
    #   renders), injects the overlay loader and sets `Cache-Control: private, no-store`, `Vary: Cookie` and
    #   `X-Robots-Tag: noindex`, and widens `frame-src` to Dialecto. An invalid cookie is cleared. A visitor's
    #   request goes to the app untouched.
    # * `POST /__dialecto/stop` clears the cookie.
    #
    # `/__dialecto/context`, `/overrides` and `/marking` do not exist here: they answer 404, and nothing in
    # this class consults the development store, the loopback checks, or any header for the origin.
    class LiveMiddleware
      PREFIX = "/__dialecto".freeze
      PARAM = "dialecto_edit".freeze
      COOKIE = "dialecto_edit".freeze
      OVERLAY = File.expand_path("assets/overlay.js", __dir__)
      JSON_HEADERS = {"content-type" => "application/json", "cache-control" => "no-store"}.freeze

      # `settings`: a DialectoRails::Config with live mode on. `clock` returns Unix seconds.
      def initialize(app, settings:, logger: nil)
        @app = app
        @settings = settings
        @logger = logger
        @origin = settings.origin
        @key = settings.public_key
        @clock = settings.clock
      end

      def call(env)
        # One thread serves many requests: never inherit a flag.
        ::DialectoRails.live_marking = false

        early = intercept(env)
        return early if early

        cookie, valid = session_state(env)
        return @app.call(env) unless cookie

        valid ? editor(env, cookie, valid) : visitor_with_stale_cookie(env)
      end

      private

      ## Answers that never reach the app

      def intercept(env)
        path = env["PATH_INFO"].to_s
        return overlay(env) if path == "#{PREFIX}/overlay.js"
        return stop(env) if path == "#{PREFIX}/stop"
        return json(404, error: "not_found") if path == PREFIX || path.start_with?("#{PREFIX}/")

        token = start_token(env)
        token ? start(env, token) : nil
      rescue => error
        @logger&.debug("dialecto-rails: live request skipped (#{error.class})")
        nil
      end

      ## 1. Start

      def start_token(env)
        return nil unless %w[GET HEAD].include?(env["REQUEST_METHOD"]) && !env["QUERY_STRING"].to_s.empty?

        env["QUERY_STRING"].split("&").each do |pair|
          name, value = pair.split("=", 2)
          return CGI.unescape(value.to_s) if CGI.unescape(name.to_s) == PARAM
        end
        nil
      end

      def start(env, token)
        headers = {"location" => own_url_without_param(env), "cache-control" => "private, no-store", "content-length" => "0"}
        begin
          now = @clock.call
          result = verify(token, now, :start)
          if result.ok?
            cookie = "#{COOKIE}=#{token}; path=/; max-age=#{result.claims["exp"] - now}; secure; httponly; samesite=lax"
            add_set_cookie(headers, cookie)
          else
            @logger&.info("dialecto-rails: launch link refused (#{result.reason})")
          end
        rescue => error
          # Whatever goes wrong, the answer still takes the token out of the address bar and the Referer.
          headers.delete("set-cookie")
          @logger&.debug("dialecto-rails: launch link not started (#{error.class})")
        end
        [303, headers, []]
      end

      # This request's own path and query, never a URL taken from input. A path that a browser could read as
      # another host ("//host", "/\host") is collapsed to the root.
      def own_url_without_param(env)
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        path = "/" unless path.match?(%r{\A/(?![/\\])[^\\\x00-\x1f\x7f]*\z})
        query = env["QUERY_STRING"].to_s.split("&").reject { |pair| CGI.unescape(pair.split("=", 2).first.to_s) == PARAM }.join("&")
        query.empty? ? path : "#{path}?#{query}"
      end

      ## 2. Each request

      # `[cookie, claims]`: the cookie's token and its verified claims, or `[token, nil]` when invalid.
      def session_state(env)
        token = cookies(env)[COOKIE]
        return nil unless token

        result = verify(token, @clock.call, :session)
        [token, result.ok? ? result.claims : nil]
      end

      def verify(token, now, phase) = LaunchToken.verify(token, @key, @origin, now, phase, repo: @settings.repo)

      def cookies(env)
        env["HTTP_COOKIE"].to_s.split(/;\s*/).each_with_object({}) do |pair, found|
          name, value = pair.split("=", 2)
          found[name] ||= value
        end
      end

      def editor(env, _token, claims)
        marked = marking_request?(env)
        ::DialectoRails.live_marking = marked
        response = begin
          @app.call(env)
        ensure
          ::DialectoRails.live_marking = false
        end
        marked ? finish(env, response, claims["exp"]) : response
      end

      def visitor_with_stale_cookie(env)
        status, headers, body = @app.call(env)
        headers = headers.dup
        add_set_cookie(headers, "#{COOKIE}=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; secure; httponly; samesite=lax")
        [status, headers, body]
      end

      # Navigations (a document or an iframe) and Turbo-style visits (a same-origin fetch that asks for HTML),
      # never forms, cross-site fetches or JSON.
      def marking_request?(env)
        %w[GET HEAD].include?(env["REQUEST_METHOD"]) && navigation?(env) &&
          env["HTTP_ACCEPT"].to_s.include?("text/html") && path_allowed?(env["PATH_INFO"].to_s)
      end

      def navigation?(env)
        case env["HTTP_SEC_FETCH_DEST"]
        when "document", "iframe" then true
        when "empty" then env["HTTP_SEC_FETCH_SITE"] == "same-origin"
        else false
        end
      end

      def path_allowed?(path)
        prefixes = @settings.paths
        return true if prefixes.nil?

        prefixes.any? do |prefix|
          base = prefix.chomp("/")
          path == base || path.start_with?(base + "/")
        end
      end

      # The cache headers come first and depend on nothing after them: a marked page must never reach a
      # shared cache, even when the editor can't be added to it.
      def finish(env, response, exp)
        status, headers, body = response
        headers = headers.dup
        set_header(headers, "cache-control", "private, no-store")
        vary_cookie(headers)
        set_header(headers, "x-robots-tag", "noindex")
        # A validator from a response with markers must never revalidate another.
        headers.delete_if { |name, _| name.casecmp?("etag") || name.casecmp?("last-modified") }
        [status, headers, editor_page(env, headers, body, exp)]
      end

      # The CSP and the loader. If either fails, the page is served marked and uncached, without the editor.
      def editor_page(env, headers, body, exp)
        widen_csp(headers)
        inject(env, headers, body, exp)
      rescue => error
        @logger&.debug("dialecto-rails: editor not added to a marked response (#{error.class})")
        body
      end

      # Buffers an HTML page to put the loader before `</head>`; anything else passes through.
      def inject(env, headers, body, exp)
        return body unless header(headers, "content-type").to_s.start_with?("text/html") && header(headers, "content-encoding").nil?

        html = +""
        body.each { |part| html << part.to_s }
        body.close if body.respond_to?(:close)
        [with_loader(env, headers, html.force_encoding(Encoding::UTF_8), exp)]
      end

      # Once the body is buffered, a failure must return the buffer, not the spent body.
      def with_loader(env, headers, html, exp)
        at = html.index("</head>")
        return html unless at

        out = html.dup.insert(at, loader_tag(env, headers, exp))
        key = headers.keys.find { |name| name.casecmp?("content-length") }
        headers[key] = out.bytesize.to_s if key
        out
      rescue => error
        @logger&.debug("dialecto-rails: loader not added (#{error.class})")
        html
      end

      def loader_tag(env, headers, exp)
        base = "#{env["SCRIPT_NAME"]}#{PREFIX}"
        nonce = Csp.script_nonce(header(headers, "content-security-policy"))
        attributes = {
          "src" => "#{base}/overlay.js?v=#{DialectoRails::VERSION}",
          "data-url" => @settings.url,
          "data-stop" => "#{base}/stop",
          "data-project" => @settings.repo,
          "data-exp" => exp.to_s,
          "nonce" => nonce
        }.compact.map { |name, value| %( #{name}="#{CGI.escapeHTML(value.to_s)}") }.join
        "<script defer#{attributes}></script>"
      end

      def widen_csp(headers)
        key = headers.keys.find { |name| name.casecmp?("content-security-policy") }
        return unless key

        origin = Config.normalize_origin(@settings.url) || "https://app.dialecto.eu"
        headers[key] = Csp.widen_frame_src(headers[key], origin)
      end

      def vary_cookie(headers)
        key = headers.keys.find { |name| name.casecmp?("vary") }
        values = key ? headers[key].to_s.split(",").map(&:strip) : []
        return if values.include?("*") || values.any? { |value| value.casecmp?("cookie") }

        set_header(headers, "vary", (values + ["Cookie"]).join(", "))
      end

      ## 3. Stop, the overlay, and the routes that don't exist

      def stop(env)
        return json(405, error: "method_not_allowed") unless env["REQUEST_METHOD"] == "POST"
        return json(403, error: "forbidden_origin") unless same_origin?(env)

        headers = {"cache-control" => "no-store", "content-length" => "0"}
        add_set_cookie(headers, "#{COOKIE}=; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT; secure; httponly; samesite=lax")
        [204, headers, []]
      end

      def same_origin?(env)
        origin = env["HTTP_ORIGIN"]
        origin.nil? ? env["HTTP_SEC_FETCH_SITE"] == "same-origin" : origin == @origin
      end

      def overlay(env)
        return json(405, error: "method_not_allowed") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])
        return json(404, error: "not_found") unless File.file?(OVERLAY)

        source = File.binread(OVERLAY)
        [200, {"content-type" => "text/javascript; charset=utf-8", "cache-control" => "public, max-age=31536000, immutable",
               "x-content-type-options" => "nosniff", "content-length" => source.bytesize.to_s},
          [(env["REQUEST_METHOD"] == "HEAD") ? "" : source]]
      end

      def json(status, body)
        text = JSON.generate(body)
        [status, JSON_HEADERS.merge("content-length" => text.bytesize.to_s), [text]]
      end

      ## Headers

      def header(headers, name)
        key = headers.keys.find { |candidate| candidate.casecmp?(name) }
        key && headers[key]
      end

      def set_header(headers, name, value)
        headers.delete_if { |key, _| key.casecmp?(name) }
        headers[name] = value
      end

      def add_set_cookie(headers, cookie)
        key = headers.keys.find { |name| name.casecmp?("set-cookie") } || "set-cookie"
        existing = headers[key]
        headers[key] =
          case existing
          when nil then cookie
          when Array then existing + [cookie]
          else "#{existing}\n#{cookie}"
          end
      end
    end
  end
end
