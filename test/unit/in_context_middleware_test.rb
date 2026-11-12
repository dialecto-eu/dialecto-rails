require "test_helper"
require "json"
require "rack/test"
require "dialecto_rails/in_context/store"
require "dialecto_rails/in_context/middleware"

class InContextMiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  InContext = DialectoRails::InContext
  Settings = Struct.new(:url, :project, :paths, :valid, keyword_init: true) do
    def url_valid? = valid
  end

  CONTEXT = {repo: "acme/shop", project: "12", branch: "main", sha: "a" * 40, dirty: [], addon: "rails@0"}.freeze
  HTML = %(<html><head><title>x</title></head><body>hi</body></html>)

  class FakeGit
    def read = CONTEXT
  end

  def setup
    @tick = 0
    @store = InContext::Store.new(clock: -> { @tick })
    @settings = Settings.new(url: "http://localhost:4500", project: "12", paths: nil, valid: true)
    @response = [200, {"content-type" => "text/html; charset=utf-8", "content-length" => HTML.bytesize.to_s}, [HTML]]
    @calls = 0
    @inner = ->(_env) { @calls += 1; @response }
    header "Host", "localhost:3000"
  end

  def app
    InContext::Middleware.new(@inner, settings: @settings, store: @store, git_context: FakeGit.new)
  end

  def post_json(path, body, headers = {})
    header "Origin", "http://localhost:3000"
    headers.each { |name, value| header name, value }
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def json = JSON.parse(last_response.body)

  ## Endpoints

  def test_context_is_served_to_a_loopback_peer
    get "/__dialecto/context"
    assert_equal 200, last_response.status
    assert_equal "acme/shop", json["repo"]
    assert_equal "no-store", last_response.headers["cache-control"]
    assert_equal 0, @calls
  end

  def test_context_refuses_a_lan_peer_that_sends_a_loopback_host
    get "/__dialecto/context", {}, "REMOTE_ADDR" => "192.168.1.20"
    assert_equal 403, last_response.status
  end

  def test_a_forwarded_for_header_does_not_make_a_lan_peer_loopback
    header "X-Forwarded-For", "127.0.0.1"
    get "/__dialecto/context", {}, "REMOTE_ADDR" => "10.0.0.5"
    assert_equal 403, last_response.status
  end

  def test_the_posts_refuse_a_lan_peer_too
    post_json "/__dialecto/marking", {on: true}
    assert_equal 200, last_response.status
    @store.set_marking(false)
    header "Origin", "http://localhost:3000"
    post "/__dialecto/marking", JSON.generate(on: true), "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "192.168.1.20"
    assert_equal 403, last_response.status
    refute @store.marking?
  end

  def test_loopback_peers_in_every_spelling_are_accepted
    ["127.0.0.1", "127.8.9.1", "::1", "::ffff:127.0.0.1"].each do |address|
      get "/__dialecto/context", {}, "REMOTE_ADDR" => address
      assert_equal 200, last_response.status, address
    end
    ["::ffff:10.0.0.1", "2001:db8::1", "", "garbage"].each do |address|
      get "/__dialecto/context", {}, "REMOTE_ADDR" => address
      assert_equal 403, last_response.status, address
    end
  end

  def test_a_foreign_host_is_refused_even_from_a_loopback_peer
    header "Host", "evil.example"
    get "/__dialecto/context"
    assert_equal 403, last_response.status
  end

  def test_ipv6_loopback_host
    header "Host", "[::1]:3000"
    get "/__dialecto/context", {}, "REMOTE_ADDR" => "::1"
    assert_equal 200, last_response.status
  end

  def test_context_refuses_cross_site_fetches_and_foreign_origins
    header "Sec-Fetch-Site", "cross-site"
    get "/__dialecto/context"
    assert_equal 403, last_response.status
    header "Sec-Fetch-Site", "same-origin"
    header "Origin", "http://evil.example"
    get "/__dialecto/context"
    assert_equal 403, last_response.status
  end

  def test_context_only_answers_get
    post "/__dialecto/context"
    assert_equal 405, last_response.status
  end

  def test_marking_turns_on_with_a_ttl_and_off_again
    post_json "/__dialecto/marking", {on: true}
    assert_equal 200, last_response.status
    assert_equal({"ok" => true, "on" => true, "ttl_ms" => 90_000}, json)
    assert @store.marking?
    @tick = 89_999
    assert @store.marking?
    @tick = 90_001
    refute @store.marking?, "the heartbeat stopped, so marking expires"
    post_json "/__dialecto/marking", {on: true}
    post_json "/__dialecto/marking", {on: false}
    refute @store.marking?
  end

  def test_marking_rejects_other_payloads
    post_json "/__dialecto/marking", {on: "yes"}
    assert_equal 400, last_response.status
    post_json "/__dialecto/marking", [1]
    assert_equal 400, last_response.status
  end

  def test_a_post_needs_this_sites_own_origin
    post "/__dialecto/marking", JSON.generate(on: true), "CONTENT_TYPE" => "application/json"
    assert_equal 403, last_response.status, "no Origin"
    header "Origin", "http://localhost:9999"
    post "/__dialecto/marking", JSON.generate(on: true), "CONTENT_TYPE" => "application/json"
    assert_equal 403, last_response.status, "another port is another origin"
    header "Origin", "http://localhost:3000"
    header "Sec-Fetch-Site", "cross-site"
    post "/__dialecto/marking", JSON.generate(on: true), "CONTENT_TYPE" => "application/json"
    assert_equal 403, last_response.status
  end

  def test_malformed_and_oversized_bodies
    header "Origin", "http://localhost:3000"
    post "/__dialecto/marking", "{nope", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
    assert_equal "invalid_json", json["error"]
    post "/__dialecto/overrides", "x" * (256 * 1024 + 1), "CONTENT_TYPE" => "application/json"
    assert_equal 413, last_response.status
  end

  def test_overrides_replace_the_whole_set
    edit = {domain: "en.yml", key: "hello", locale: "en", to: "Howdy"}
    post_json "/__dialecto/overrides", {edits: [edit, edit.merge(locale: "not a locale!")]}
    assert_equal 200, last_response.status
    assert_equal({"ok" => true, "applied" => 1, "ignored" => 1}, json)
    assert_equal({to: "Howdy"}, @store.override("en.yml", "hello", "en"))
    post_json "/__dialecto/overrides", {edits: []}
    assert_nil @store.override("en.yml", "hello", "en")
  end

  def test_overrides_reject_a_malformed_list
    post_json "/__dialecto/overrides", {edits: [{domain: "d"}]}
    assert_equal 400, last_response.status
    post_json "/__dialecto/overrides", {edits: "x"}
    assert_equal 400, last_response.status
  end

  def test_unknown_routes_are_404
    get "/__dialecto/nope"
    assert_equal 404, last_response.status
  end

  def test_an_endpoint_bug_is_a_bare_json_500
    broken = Object.new
    def broken.read = raise("boom")
    middleware = InContext::Middleware.new(@inner, settings: @settings, store: @store, git_context: broken)
    status, _headers, body = middleware.call(Rack::MockRequest.env_for("/__dialecto/context", "HTTP_HOST" => "localhost", "REMOTE_ADDR" => "127.0.0.1"))
    assert_equal 500, status
    assert_equal({"error" => "internal"}, JSON.parse(body.join))
  end

  ## The loader

  def test_the_loader_goes_before_the_closing_head_and_length_is_recomputed
    get "/"
    body = last_response.body
    assert_includes body, %(<script defer src="http://localhost:4500/assets/in-context/overlay.js" data-url="http://localhost:4500")
    assert_includes body, %(data-context="/__dialecto/context" data-overrides="/__dialecto/overrides" data-marking="/__dialecto/marking" data-project="12"></script></head>)
    assert_equal body.bytesize.to_s, last_response.headers["content-length"]
  end

  def test_the_loader_honours_script_name
    get "/", {}, "SCRIPT_NAME" => "/app"
    assert_includes last_response.body, %(data-context="/app/__dialecto/context")
  end

  def test_the_loader_carries_the_pages_csp_nonce
    @response = [200, {"content-type" => "text/html", "content-security-policy" => "script-src 'self' 'nonce-abc123=='"}, [HTML]]
    get "/"
    assert_includes last_response.body, %( nonce="abc123==")
  end

  def test_no_loader_where_it_does_not_belong
    get "/", {}, "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest"
    refute_includes last_response.body, "overlay.js"
    get "/", {}, "HTTP_TURBO_FRAME" => "frame-1"
    refute_includes last_response.body, "overlay.js"
    get "/", {}, "HTTP_SEC_FETCH_DEST" => "iframe"
    refute_includes last_response.body, "overlay.js"
    post "/", {}
    refute_includes last_response.body, "overlay.js"
    get "/", {}, "REMOTE_ADDR" => "192.168.1.20"
    refute_includes last_response.body, "overlay.js"
    header "Host", "evil.example"
    get "/"
    refute_includes last_response.body, "overlay.js"
  end

  def test_no_loader_for_other_content_or_a_body_without_head
    @response = [200, {"content-type" => "application/json"}, [HTML]]
    get "/"
    refute_includes last_response.body, "overlay.js"
    @response = [200, {"content-type" => "text/event-stream"}, [HTML]]
    get "/"
    refute_includes last_response.body, "overlay.js"
    @response = [200, {"content-type" => "text/html"}, ["<p>fragment</p>"]]
    get "/"
    assert_equal "<p>fragment</p>", last_response.body
    @response = [200, {"content-type" => "text/html", "content-encoding" => "gzip"}, [HTML]]
    get "/"
    assert_equal HTML, last_response.body
  end

  def test_the_loader_respects_paths_and_a_disabled_url
    @settings.paths = ["/admin"]
    get "/"
    refute_includes last_response.body, "overlay.js"
    get "/admin/users"
    assert_includes last_response.body, "overlay.js"
    @settings.valid = false
    get "/admin/users"
    refute_includes last_response.body, "overlay.js"
  end

  def test_the_page_is_served_untouched_when_the_loader_cannot_be_built
    @settings.url = nil
    get "/"
    assert_equal 200, last_response.status
    assert_equal HTML, last_response.body
  end
end
