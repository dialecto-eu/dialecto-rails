require "test_helper"
require "json"
require "rack/test"
require "active_support"
require "active_support/isolated_execution_state"
require "dialecto_rails"
require "dialecto_rails/in_context/live_middleware"

# The Rack half of live-site editing against the shared launch-token vectors (test/support/live_edit_vectors.json
# at the repo root, which is not copied here).
class InContextLiveMiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  InContext = DialectoRails::InContext
  VECTORS = JSON.parse(File.read(File.expand_path("../../../../test/support/live_edit_vectors.json", __dir__)))
  CASES = VECTORS["cases"].to_h { |entry| [entry["name"], entry] }
  VALID = CASES.fetch("valid")
  HTML = %(<html><head><title>x</title></head><body>hi</body></html>)

  def setup
    @now = VALID["now"]
    @seen = []
    # Nothing may read or write the session: a token there risks CookieOverflow, and loading it for a visitor
    # makes the session store write a cookie.
    @session = Class.new(Hash) do
      def [](*) = raise("the session must not be read")
      def []=(*)
        raise("the session must not be written")
      end
      def delete(*) = raise("the session must not be written")
    end.new
    @origin = VECTORS["origin"]
    @public_key = VECTORS["public"]
    @response = [200, {"content-type" => "text/html; charset=utf-8", "content-length" => HTML.bytesize.to_s}, [HTML]]
    header "Sec-Fetch-Dest", "document"
    header "Accept", "text/html,application/xhtml+xml"
    ::DialectoRails.live_marking = false
  end

  def teardown = (::DialectoRails.live_marking = false)

  def settings(extra = {})
    DialectoRails::Config.new({mode: :live, repo: @settings_repo || "example/app", origin: @origin, public_key: @public_key,
                               clock: @clock || -> { @now }, url: "https://app.dialecto.eu"}.merge(extra), {})
  end

  def app
    inner = lambda do |env|
      @seen << {marked: ::DialectoRails.live_marking?, path: env["PATH_INFO"], session: @session.dup}
      @response
    end
    session = @session
    outer = ->(env) { InContext::LiveMiddleware.new(inner, settings: settings).call(env.merge("rack.session" => session)) }
    outer
  end

  def token(name) = CASES.fetch(name)["token"]

  def started
    get "/dash?dialecto_edit=#{token("valid")}"
    assert_equal 303, last_response.status
    set_cookie "dialecto_edit=#{token("valid")}"
  end

  def cookies_of(response) = Array(response.headers["set-cookie"]).flat_map { |value| value.split("\n") }

  def marked_request?(path = "/dash") = (get(path) && @seen.last[:marked])

  ## Visitors

  def test_a_visitor_reaches_the_app_untouched
    get "/dash?x=1"
    assert_equal 200, last_response.status
    assert_equal HTML, last_response.body
    assert_equal @response[1], last_response.headers.to_h.slice(*@response[1].keys)
    assert_nil last_response.headers["set-cookie"]
    assert_equal [{marked: false, path: "/dash", session: {}}], @seen
  end

  def test_the_session_is_not_touched_by_a_visitor_or_an_editor
    get "/dash"
    assert_equal 200, last_response.status
    started
    get "/dash"
    assert_equal 200, last_response.status
  end

  ## Start

  def test_a_valid_token_answers_303_without_the_parameter_and_sets_the_cookie
    get "/dash?a=1&dialecto_edit=#{token("valid")}&b=2"
    assert_equal 303, last_response.status
    assert_equal "/dash?a=1&b=2", last_response.headers["location"]
    assert_equal "private, no-store", last_response.headers["cache-control"]
    cookie = cookies_of(last_response).first
    assert_equal "dialecto_edit=#{token("valid")}; path=/; max-age=28790; secure; httponly; samesite=lax", cookie
    assert_empty @seen, "the app never sees the start request"
  end

  def test_the_redirect_target_is_never_taken_from_input
    ["//evil.example.com/x", "/\\evil.example.com", "/ok\\path"].each do |path|
      get "/", {}, "PATH_INFO" => path, "QUERY_STRING" => "dialecto_edit=#{token("valid")}"
      assert_equal "/", last_response.headers["location"], path
    end
    get "/", {}, "SCRIPT_NAME" => "/app", "PATH_INFO" => "/dash", "QUERY_STRING" => "dialecto_edit=#{token("valid")}&q=%C3%A9"
    assert_equal "/app/dash?q=%C3%A9", last_response.headers["location"]
  end

  def test_a_failure_while_starting_still_removes_the_token_from_the_url_and_sets_no_cookie
    @clock = -> { raise "clock failed" }
    get "/dash?a=1&dialecto_edit=#{token("valid")}"

    assert_equal 303, last_response.status
    assert_equal "/dash?a=1", last_response.headers["location"]
    assert_equal "private, no-store", last_response.headers["cache-control"]
    assert_nil last_response.headers["set-cookie"]
    assert_empty @seen
  end

  def test_only_a_get_starts_a_session
    post "/dash?dialecto_edit=#{token("valid")}"
    assert_equal 200, last_response.status
    assert_nil last_response.headers["set-cookie"]
  end

  def test_every_vector_either_starts_a_session_or_is_ignored_and_the_parameter_is_removed
    VECTORS["cases"].select { |entry| entry["phase"] == "start" }.each do |entry|
      @now = entry["now"]
      @origin = entry["origin"]
      @public_key = entry["public"] || VECTORS["public"]
      get "/dash?dialecto_edit=#{entry["token"]}"

      assert_equal 303, last_response.status, entry["name"]
      assert_equal "/dash", last_response.headers["location"], entry["name"]
      assert_equal entry["expect"] == "ok", cookies_of(last_response).any? { |line| line.start_with?("dialecto_edit=") }, entry["name"]
    end
  end

  def test_the_verifier_names_each_vectors_outcome_in_both_phases
    VECTORS["cases"].each do |entry|
      key = DialectoRails::Config.new({public_key: entry["public"] || VECTORS["public"]}, {}).public_key
      result = InContext::LaunchToken.verify(entry["token"], key, entry["origin"], entry["now"], entry["phase"].to_sym)
      if entry["expect"] == "ok"
        assert result.ok?, entry["name"]
        assert_equal "example/app", result.claims["repo"]
      else
        assert_equal entry["expect"].to_sym, result.reason, entry["name"]
      end
    end
  end

  def test_malformed_tokens_never_raise
    key = "\x01".b * 32
    ["", ".", "a.b", "a.b.c", "@@.@@", nil, 5, "A" * 5000].each do |text|
      refute InContext::LaunchToken.verify(text, key, @origin, 1, :start).ok?, text.inspect
    end
  end

  ## An editor's requests

  def test_the_next_request_is_marked_and_carries_the_loader_and_cache_headers
    started
    get "/dash"

    assert_equal true, @seen.last[:marked]
    assert_equal "private, no-store", last_response.headers["cache-control"]
    assert_equal "Cookie", last_response.headers["vary"]
    assert_equal "noindex", last_response.headers["x-robots-tag"]
    assert_match %r{<script defer src="/__dialecto/overlay\.js\?v=#{Regexp.escape(DialectoRails::VERSION)}"}, last_response.body
    assert_includes last_response.body, 'data-exp="1800028800"'
    assert_includes last_response.body, 'data-project="example/app"'
    assert_equal last_response.body.bytesize.to_s, last_response.headers["content-length"]
  end

  def test_the_flag_is_off_again_after_the_request_and_after_an_exception
    started
    get "/dash"
    refute ::DialectoRails.live_marking?

    @response = ->(_env) { raise "app bug" }
    middleware = InContext::LiveMiddleware.new(->(_env) { raise "app bug" }, settings: settings)
    env = Rack::MockRequest.env_for("/dash", "HTTP_COOKIE" => "dialecto_edit=#{token("valid")}", "HTTP_SEC_FETCH_DEST" => "document",
      "HTTP_ACCEPT" => "text/html")
    assert_raises(RuntimeError) { middleware.call(env) }
    refute ::DialectoRails.live_marking?
  end

  def test_only_html_navigations_are_marked
    started
    header "Sec-Fetch-Dest", "empty"
    refute marked_request?
    header "Sec-Fetch-Dest", "document"
    header "Accept", "application/json"
    refute marked_request?
    header "Accept", "text/html"
    assert marked_request?
    header "Sec-Fetch-Dest", "iframe"
    assert marked_request?
    post "/dash"
    refute @seen.last[:marked]
    head "/dash"
    assert @seen.last[:marked]
  end

  def test_a_page_with_no_sec_fetch_dest_is_not_marked
    started
    header "Sec-Fetch-Dest", ""
    refute marked_request?
  end

  def test_paths_outside_paths_are_not_marked
    started
    @paths = ["/admin"]
    app = InContext::LiveMiddleware.new(->(_env) { @response }, settings: settings(paths: ["/admin"]))
    env = Rack::MockRequest.env_for("/dash", "HTTP_COOKIE" => "dialecto_edit=#{token("valid")}", "HTTP_SEC_FETCH_DEST" => "document",
      "HTTP_ACCEPT" => "text/html")
    assert_nil app.call(env)[1]["x-robots-tag"]
  end

  def test_the_frame_src_gains_dialecto_on_editing_responses_only
    @response = [200, @response[1].merge("content-security-policy" => "default-src 'self'; script-src 'self'"), [HTML]]
    get "/dash"
    assert_equal "default-src 'self'; script-src 'self'", last_response.headers["content-security-policy"]

    started
    get "/dash"
    assert_equal "default-src 'self'; script-src 'self'; frame-src 'self' https://app.dialecto.eu",
      last_response.headers["content-security-policy"]
  end

  def test_widen_frame_src
    csp = InContext::Csp
    assert_equal "frame-src 'self' https://d.example", csp.widen_frame_src("frame-src 'self'", "https://d.example")
    assert_equal "frame-src https://d.example; img-src *", csp.widen_frame_src("frame-src 'none'; img-src *", "https://d.example")
    assert_equal "child-src blob:; frame-src blob: https://d.example", csp.widen_frame_src("child-src blob:", "https://d.example")
    assert_equal "script-src 'self'", csp.widen_frame_src("script-src 'self'", "https://d.example")
  end

  # The browser enforces every policy, so each one is widened on its own.
  def test_widen_frame_src_widens_each_of_several_policies
    csp = InContext::Csp
    joined = "default-src 'self'\nframe-src 'none'"
    assert_equal "default-src 'self'; frame-src 'self' https://d.example\nframe-src https://d.example",
      csp.widen_frame_src(joined, "https://d.example")
    assert_equal ["default-src 'self'; frame-src 'self' https://d.example", "frame-src https://d.example"],
      csp.widen_frame_src(joined.split("\n"), "https://d.example")
  end

  def test_the_nonce_of_the_apps_policy_goes_on_the_loader
    @response = [200, @response[1].merge("content-security-policy" => "script-src 'nonce-abc123' 'self'"), [HTML]]
    started
    get "/dash"
    assert_includes last_response.body, 'nonce="abc123"'
  end

  def test_the_nonce_is_the_one_that_governs_scripts_not_the_first_in_the_policy
    {
      "style-src 'nonce-A'; script-src 'nonce-B'" => "B",
      "default-src 'nonce-C'; img-src 'self'" => "C",
      "default-src 'nonce-C'; script-src 'nonce-B'; script-src-elem 'nonce-E'" => "E"
    }.each do |policy, nonce|
      @response = [200, @response[1].merge("content-security-policy" => policy), [HTML]]
      started
      get "/dash"
      assert_includes last_response.body, %(nonce="#{nonce}"), policy
      refute_includes last_response.body, %(nonce="A"), policy
    end
  end

  def test_a_page_without_a_script_nonce_gets_a_loader_without_the_attribute
    @response = [200, @response[1].merge("content-security-policy" => "style-src 'nonce-A'; script-src 'self'"), [HTML]]
    started
    get "/dash"
    assert_includes last_response.body, "<script defer src="
    refute_includes last_response.body, "nonce="
  end

  def test_the_nonce_is_read_across_every_policy_header
    @response = [200, @response[1].merge("content-security-policy" => "img-src 'self'\nstyle-src 'nonce-A'; script-src 'nonce-B'"), [HTML]]
    started
    get "/dash"
    assert_includes last_response.body, 'nonce="B"'
  end

  ## Invalid cookies and stop

  def test_an_expired_cookie_is_cleared_and_the_request_is_a_visitors
    started
    @now = CASES.fetch("past_exp")["now"]
    get "/dash"

    refute @seen.last[:marked]
    assert cookies_of(last_response).any? { |line| line.start_with?("dialecto_edit=;") && line.include?("max-age=0") }
    assert_nil last_response.headers["x-robots-tag"]
  end

  def test_forged_cookies_are_cleared_and_ignored
    %w[flipped_signature_byte signed_with_manifest_purpose].each do |name|
      set_cookie "dialecto_edit=#{token(name)}"
      get "/dash"
      refute @seen.last[:marked], name
      assert cookies_of(last_response).any? { |line| line.include?("max-age=0") }, name
    end
  end

  def test_a_token_for_another_repo_is_refused_ignoring_case_in_the_match
    @settings_repo = "someone/else"
    get "/dash?dialecto_edit=#{token("valid")}"
    assert_empty cookies_of(last_response)

    @settings_repo = "EXAMPLE/App"
    get "/dash?dialecto_edit=#{token("valid")}"
    assert_equal 1, cookies_of(last_response).length
  end

  def test_a_refused_launch_link_is_logged_by_reason_and_never_with_the_token
    lines = []
    logger = Object.new
    logger.define_singleton_method(:info) { |line| lines << line }
    @now = CASES.fetch("past_start_by")["now"]
    middleware = InContext::LiveMiddleware.new(->(_env) { @response }, settings: settings, logger: logger)
    middleware.call(Rack::MockRequest.env_for("/dash?dialecto_edit=#{token("past_start_by")}"))

    assert_equal ["dialecto-rails: launch link refused (late)"], lines
  end

  def test_a_turbo_style_visit_is_marked_but_a_cross_site_or_json_fetch_is_not
    started
    header "Sec-Fetch-Dest", "empty"
    header "Accept", "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    header "Sec-Fetch-Site", "same-origin"
    assert marked_request?

    header "Sec-Fetch-Site", "cross-site"
    refute marked_request?

    header "Sec-Fetch-Site", "same-origin"
    header "Accept", "application/json"
    refute marked_request?
  end

  def test_marked_responses_lose_their_validators
    @response = [200, @response[1].merge("etag" => %(W/"abc"), "last-modified" => "Wed, 01 Jan 2025 00:00:00 GMT"), [HTML]]
    get "/dash"
    assert_equal %(W/"abc"), last_response.headers["etag"], "a visitor's response keeps them"

    started
    get "/dash"
    assert_nil last_response.headers["etag"]
    assert_nil last_response.headers["last-modified"]
  end

  def test_a_marked_page_is_never_cacheable_even_when_the_editor_cannot_be_added
    @response = [200, @response[1].merge("content-security-policy" => "default-src 'self'", "cache-control" => "public, max-age=600"), [HTML]]
    original = InContext::Csp.method(:widen_frame_src)
    InContext::Csp.define_singleton_method(:widen_frame_src) { |*| raise "boom" }
    started
    get "/dash"
    assert @seen.last[:marked]
    assert_equal 200, last_response.status
    assert_equal "private, no-store", last_response.headers["cache-control"]
    assert_includes last_response.headers["vary"], "Cookie"
    assert_equal HTML, last_response.body
  ensure
    InContext::Csp.define_singleton_method(:widen_frame_src, original)
  end

  def test_live_stays_off_without_raw_ed25519_keys
    config = DialectoRails::Config.new({mode: :live, repo: "a/b", origin: "https://x.example", public_key: VECTORS["public"]}, {})
    original = DialectoRails::Config.method(:ed25519?)
    DialectoRails::Config.define_singleton_method(:ed25519?) { false }
    refute config.live?
    assert_equal ["the openssl gem is older than 3.2, which Ed25519 keys need: add gem \"openssl\", \">= 3.2\" to the Gemfile"],
      config.live_problems
  ensure
    DialectoRails::Config.define_singleton_method(:ed25519?, original) if original
  end

  def test_live_problems_name_what_is_missing
    config = ->(options) { DialectoRails::Config.new(options, {}) }
    assert_equal [], config.call(mode: :live, repo: "a/b", origin: "https://x.example", public_key: VECTORS["public"]).live_problems
    assert_equal [], config.call({}).live_problems
    assert_equal ["repo is not set", "origin is not set or is not an http(s) origin", "public_key is not set or is not an ed25519:<base64url> key"],
      config.call(mode: :live).live_problems
  end

  def test_a_token_for_another_origin_or_signed_by_another_key_is_refused
    @origin = "https://evil.example.com"
    set_cookie "dialecto_edit=#{token("valid")}"
    refute marked_request?

    @origin = VECTORS["origin"]
    @public_key = CASES.fetch("verified_with_another_key")["public"]
    refute marked_request?
  end

  def test_the_origin_is_the_configured_one_never_a_header
    started
    header "Host", "evil.example.com"
    header "X-Forwarded-Host", "evil.example.com"
    assert marked_request?
  end

  def test_stop_clears_the_cookie
    started
    header "Origin", @origin
    post "/__dialecto/stop"
    assert_equal 204, last_response.status
    assert cookies_of(last_response).any? { |line| line.start_with?("dialecto_edit=;") && line.include?("max-age=0") }
  end

  def test_stop_refuses_a_foreign_origin_and_a_get
    started
    header "Origin", "https://evil.example.com"
    post "/__dialecto/stop"
    assert_equal 403, last_response.status
    header "Origin", @origin
    get "/__dialecto/stop"
    assert_equal 405, last_response.status
  end

  ## What does not exist

  def test_the_development_routes_answer_404_from_loopback_with_a_loopback_host
    header "Host", "localhost:3000"
    header "Origin", "http://localhost:3000"
    [[:get, "/__dialecto/context"], [:post, "/__dialecto/overrides"], [:post, "/__dialecto/marking"], [:get, "/__dialecto/other"]].each do |verb, path|
      public_send(verb, path, "{}", "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/json")
      assert_equal 404, last_response.status, path
    end
    assert_empty @seen, "none of them reached the app either"
  end

  def test_the_overlay_is_served_with_a_year_long_immutable_cache
    get "/__dialecto/overlay.js?v=1"
    assert_equal 200, last_response.status
    assert_equal "public, max-age=31536000, immutable", last_response.headers["cache-control"]
    assert_includes last_response.body, "createBridge"
  end

  def test_unmarked_restores_the_flag_even_on_a_raise
    ::DialectoRails.live_marking = true
    inside = nil
    ::DialectoRails.unmarked { inside = ::DialectoRails.live_marking? }
    assert_equal false, inside
    assert ::DialectoRails.live_marking?

    assert_raises(RuntimeError) { ::DialectoRails.unmarked { raise "boom" } }
    assert ::DialectoRails.live_marking?
  end

  def test_a_thread_does_not_inherit_the_flag
    ::DialectoRails.live_marking = true
    assert_equal false, Thread.new { ::DialectoRails.live_marking? }.value
  end
end
