require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "dialecto_rails/in_context/marker"

# Boots a real production Rails app twice, in child processes: with live-site editing configured and without
# the add-on's config (the same app, which is what a visitor must get byte for byte). Needs the `rails` gem.
class RailsLiveTest < Minitest::Test
  Marker = DialectoRails::InContext::Marker
  PROBE = File.expand_path("../support/rails_live_probe.rb", __dir__)
  VECTORS = File.expand_path("../../../../test/support/live_edit_vectors.json", __dir__)
  EN = <<~YAML
    en:
      hello: Hello
      greet: "Hi %{name}"
      inbox:
        messages:
          one: "%{count} message"
          other: "%{count} messages"
  YAML

  def self.boot(live)
    root = Dir.mktmpdir("dialecto-rails-live")
    FileUtils.mkdir_p(File.join(root, "config/locales"))
    File.write(File.join(root, "config/locales/en.yml"), EN)
    env = {"RAILS_ENV" => "production", "DIALECTO_PROBE_ROOT" => root, "DIALECTO_PROBE_VECTORS" => VECTORS,
           "DIALECTO_PROBE_LIVE" => live ? "1" : "0"}
    out, err, status = Open3.capture3(env, RbConfig.ruby, PROBE)
    line = out.lines.reverse.find { |text| text.start_with?("PROBE:") }
    raise "probe failed: #{err.lines.first(8).join}#{out.lines.last(3).join}" unless status.success? && line

    JSON.parse(line.delete_prefix("PROBE:"))
  ensure
    FileUtils.remove_entry(root) if root
  end

  def self.live = @live ||= boot(true)

  def self.bare = @bare ||= boot(false)

  def live = self.class.live

  def bare = self.class.bare

  def marked?(text) = text.to_s.include?(Marker::OPEN)

  def paragraph(response, name) = response["body"][%r{<p id="#{name}">(.*?)</p>}m, 1]

  # Request ids and timings are per request; nothing else may differ.
  def comparable(response)
    response.merge("headers" => response["headers"].reject { |name, _| %w[x-request-id x-runtime].include?(name.downcase) })
  end

  def test_a_visitor_gets_the_bytes_of_the_same_app_without_the_add_on
    assert_equal 200, live["visitor"]["status"]
    assert_equal comparable(bare["visitor"]), comparable(live["visitor"])
    assert_equal comparable(bare["visitor_json"]), comparable(live["visitor_json"])
    refute marked?(live["visitor"]["body"])
    refute_includes live["visitor"]["body"], "overlay.js"
    assert_nil live["visitor"]["headers"]["set-cookie"], "a visitor's response carries no cookie, session included"
  end

  def test_a_valid_launch_token_answers_303_without_the_parameter_and_sets_the_cookie
    start = live["start"]
    assert_equal 303, start["status"]
    assert_equal "/dash?x=1&y=2", start["headers"]["location"]
    cookie = Array(start["headers"]["set-cookie"]).flat_map { |value| value.split("\n") }.find { |line| line.start_with?("dialecto_edit=") }
    assert_match(/; secure/i, cookie)
    assert_match(/; httponly/i, cookie)
    assert_match(/; samesite=lax/i, cookie)
    assert_match(%r{; path=/(;|\z)}i, cookie)
    assert_match(/; max-age=28790/i, cookie)
    assert_equal ["dialecto_edit"], live["cookies"], "no session cookie: the session is never touched"
  end

  def test_the_next_request_is_marked_with_the_loader_and_the_cache_headers
    editor = live["editor"]
    assert_equal 200, editor["status"]
    assert marked?(paragraph(editor, "hello")), "the page text carries markers"
    assert marked?(paragraph(editor, "greet"))
    assert marked?(paragraph(editor, "plural"))
    assert_match(%r{<script defer src="/__dialecto/overlay\.js\?v=#{Regexp.escape(DialectoRails::VERSION)}"}, editor["body"])
    assert_includes editor["body"], 'data-exp="1800028800"'
    refute_includes editor["body"], "data-context"
    assert_equal "private, no-store", editor["headers"]["cache-control"]
    assert_includes editor["headers"]["vary"].split(/,\s*/), "Cookie"
    assert_equal "noindex", editor["headers"]["x-robots-tag"]
    assert_equal "default-src 'self'; script-src 'self'; frame-src 'self' https://app.dialecto.eu", editor["headers"]["content-security-policy"]
    assert_equal "untouched", paragraph(editor, "session")
    assert_nil editor["headers"]["etag"]
  end

  def test_an_editors_cold_fragment_is_neither_cached_nor_marked_for_the_visitor_who_follows
    editor = live["editor"]
    assert marked?(paragraph(editor, "cached")), "rendered fresh for the editor, with markers, and not stored"

    after = live["visitor_after"]
    assert_equal "Hello", paragraph(after, "cached")
    refute marked?(after["body"]), "no marker reaches a visitor through the cache"
    assert_includes live["visitor"]["body"], "Hello"
  end

  def test_the_launch_token_is_filtered_out_of_the_request_log
    assert_includes live["filter_parameters"], "dialecto_edit"
    refute_includes bare["filter_parameters"], "dialecto_edit"
  end

  def test_a_mail_sent_inside_unmarked_carries_no_markers_and_one_outside_does
    editor = live["editor"]
    refute marked?(paragraph(editor, "mail")), "wrapped in DialectoRails.unmarked"
    assert marked?(paragraph(editor, "mail_unwrapped")), "the control: without the wrapper the editor's markers reach the mail"
  end

  def test_a_post_and_a_json_fetch_in_the_same_session_are_unmarked
    refute marked?(live["post"]["body"])
    refute marked?(live["api"]["body"])
    assert_equal "Hello", live["post"]["body"]
    assert_equal({"hello" => "Hello"}, JSON.parse(live["api"]["body"]))
  end

  def test_the_development_routes_do_not_exist_even_from_loopback_with_a_loopback_host
    assert_equal({"context" => 404, "overrides" => 404, "marking" => 404}, live["routes"])
  end

  def test_stop_clears_the_cookie
    assert_equal 204, live["stop"]["status"]
    cleared = Array(live["stop"]["headers"]["set-cookie"]).flat_map { |value| value.split("\n") }
    assert cleared.any? { |line| line.start_with?("dialecto_edit=;") && line.downcase.include?("max-age=0") }
    after = live["after_stop"]
    refute marked?(after["body"])
    refute_equal "private, no-store", after["headers"]["cache-control"]
  end

  def test_without_live_config_nothing_is_loaded_and_a_launch_token_does_nothing
    assert_empty bare["stack"].grep(/Dialecto/)
    assert_empty bare["hooked"]
    assert_empty bare["constants"]
    assert_equal 200, bare["start"]["status"]
    assert_equal [], bare["cookies"]
    refute marked?(bare["editor"]["body"])
  end

  def test_live_mode_holds_no_development_machinery
    assert_includes live["stack"], "DialectoRails::InContext::LiveMiddleware"
    refute_includes live["stack"], "DialectoRails::InContext::Middleware"
    refute_includes live["constants"], "DialectoRails::InContext::Store"
    refute_includes live["constants"], "DialectoRails::InContext::Runtime"
    refute_includes live["constants"], "DialectoRails::InContext::GitContext"
    assert_operator live["stack"].index("DialectoRails::InContext::LiveMiddleware"), :>,
      live["stack"].index("ActionDispatch::Session::CookieStore")
  end
end
