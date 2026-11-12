require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "dialecto_rails/in_context/marker"

# Boots a real Rails app per environment, in a child process (a Rails app boots once per process, and the
# production guard is about what a booted production process holds). Needs the `rails` gem; the CI matrix
# supplies it for each supported Rails.
class RailtieTest < Minitest::Test
  Marker = DialectoRails::InContext::Marker
  PROBE = File.expand_path("../support/rails_probe.rb", __dir__)

  EN = <<~YAML
    en:
      hello: Hello
      greet: "Hi %{name}"
      banner_html: "<b>Welcome</b>"
      only_english: English only
      pages:
        home:
          title: Home
      inbox:
        messages:
          one: "%{count} message"
          other: "%{count} messages"
  YAML
  ES = <<~YAML
    es:
      hello: Hola
      inbox:
        messages:
          one: "%{count} mensaje"
          other: "%{count} mensajes"
  YAML

  def self.boot(env, extra = {})
    root = Dir.mktmpdir("dialecto-rails-app")
    FileUtils.mkdir_p(File.join(root, "config/locales"))
    File.write(File.join(root, "config/locales/en.yml"), EN)
    File.write(File.join(root, "config/locales/es.yml"), ES)
    out, err, status = Open3.capture3({"RAILS_ENV" => env, "DIALECTO_PROBE_ROOT" => root}.merge(extra), RbConfig.ruby, PROBE)
    line = out.lines.reverse.find { |text| text.start_with?("PROBE:") }
    raise "probe failed (#{env}): #{err.lines.first(8).join}#{out.lines.last(3).join}" unless status.success? && line

    JSON.parse(line.delete_prefix("PROBE:"))
  ensure
    FileUtils.remove_entry(root) if root
  end

  def self.facts(env, extra = {}) = (@facts ||= {})[[env, extra]] ||= boot(env, extra)

  def development = self.class.facts("development")

  def segments(body) = Marker.parse(body)

  def paragraph(facts, name)
    facts.fetch("on")["body"][%r{<p id="#{name}">(.*?)</p>}m, 1]
  end

  ## The production guard (spec-0023 §7.1)

  %w[production test staging].each do |env|
    define_method("test_#{env}_gets_nothing") do
      facts = self.class.facts(env)
      assert_empty facts["stack"].grep(/Dialecto/), "no middleware"
      assert_empty facts["hooked"], "no ancestor change"
      assert_empty facts["routes"], "no route"
      assert_empty facts["constants"], "no DialectoRails::InContext constant is even loaded"
      refute_match(/overlay\.js/, facts["on"]["body"].to_s)
      assert_empty segments(facts["on"]["body"].to_s), "no marker characters in a rendered page"
      refute_includes facts["on"]["body"].to_s, Marker::OPEN
      assert_includes facts["csp"], "script-src 'self'", "the app's own policy is left as it is"
      refute_includes facts["csp"], "localhost:4500"
    end
  end

  def test_a_disabled_development_app_gets_nothing_either
    facts = self.class.facts("development", "DIALECTO_PROBE_DISABLED" => "1")
    assert_empty facts["stack"].grep(/Dialecto/)
    assert_empty facts["hooked"]
    assert_empty facts["constants"]
  end

  def test_the_environment_variable_turns_development_off
    facts = self.class.facts("development", "DIALECTO_IN_CONTEXT" => "off")
    assert_empty facts["stack"].grep(/Dialecto/)
    assert_empty facts["hooked"]
  end

  ## Development

  def test_the_middleware_is_first_and_the_hook_is_on_the_backend_class
    assert_equal "DialectoRails::InContext::Middleware", development["stack"].first
    assert_equal ["DialectoRails::InContext::BackendHook"], development["hooked"]
  end

  def test_nothing_is_marked_until_the_editor_opens
    assert_empty segments(development["off"]["body"])
    assert_includes development["off"]["body"], "overlay.js", "the loader is in the page already"
  end

  def test_the_loader_is_injected_into_the_page_head
    body = development["off"]["body"]
    assert_includes body, %(src="http://localhost:4500/assets/in-context/overlay.js")
    assert_includes body, %(data-context="/__dialecto/context")
    assert_match(%r{<script defer [^>]*></script></head>}, body)
    assert_equal body.bytesize.to_s, development["off"]["headers"]["content-length"].to_s if development["off"]["headers"]["content-length"]
  end

  def test_marking_on_marks_every_project_string
    assert_equal 200, development["marking"]["status"]
    found = segments(development["on"]["body"]).to_h { |segment| [segment.key, segment] }
    assert_equal ["en.yml", "en", "Hello"], [found["hello"].domain, found["hello"].locale, found["hello"].text]
    assert_equal({"name" => "Ana"}, found["greet"].args)
    assert_equal "pages.home.title", found["pages.home.title"].key
    assert_equal true, found["banner_html"].args["__html"]
    assert_equal "<b>Welcome</b>", found["banner_html"].text, "the _html text is not escaped"
  end

  def test_a_plural_is_marked_at_its_root
    plural = segments(development["on"]["body"]).find { |segment| segment.key == "inbox.messages" }
    assert_equal "0 messages", plural.text
    assert_equal [1, 0], [plural.args["__form"], plural.args["__n"]]
    one = segments(development["one"]["body"]).find { |segment| segment.key == "inbox.messages" }
    assert_equal [0, "1 message"], [one.args["__form"], one.text]
  end

  def test_fallback_text_is_marked_with_the_locale_that_supplied_it
    found = segments(development["spanish"]["body"]).to_h { |segment| [segment.key, segment] }
    assert_equal "es", found["hello"].locale
    assert_equal "en", found["only_english"].locale
    assert_equal "es.yml", found["hello"].domain
    assert_equal "en.yml", found["only_english"].domain
  end

  def test_strings_the_project_does_not_hold_are_left_alone
    body = development["on"]["body"]
    assert_equal "Fallback text", paragraph(development, "default")
    keys = segments(body).map(&:key)
    refute_includes keys, "nope.nothing"
    refute_includes keys, "date.formats.default"
  end

  def test_the_page_text_is_unchanged_by_the_markers
    clean = Marker.strip(development["on"]["body"].sub(/<script defer.*?<\/script>/, ""))
    plain = development["off"]["body"].sub(/<script defer.*?<\/script>/, "")
    assert_equal plain, clean
  end

  def test_drafts_apply_on_the_next_render
    assert_equal 200, development["overrides"]["status"]
    assert_equal 3, JSON.parse(development["overrides"]["body"])["applied"]
    drafted = segments(development["drafted"]["body"]).to_h { |segment| [segment.key, segment] }
    assert_equal "Howdy", drafted["hello"].text
    assert_equal "3 draft messages", drafted["inbox.messages"].text
  end

  def test_an_html_draft_with_a_script_renders_without_it
    body = development["drafted"]["body"]
    refute_includes body, "<script>alert", "the script tag is gone (its text may stay as inert text)"
    html = segments(body).find { |segment| segment.key == "banner_html" }
    assert_includes html.text, "<b>ok</b>"
  end

  def test_the_endpoints_refuse_a_lan_peer_that_sends_host_localhost
    assert_equal 200, development["context"]["status"]
    assert_equal 403, development["lan"]["status"]
    assert_equal 403, development["lan_marking"]["status"]
  end

  def test_the_page_without_a_head_is_untouched
    assert_equal "<p>no head</p>", development["raw"]["body"]
  end

  def test_the_overlay_origin_joins_the_apps_csp_and_the_loader_carries_the_nonce
    assert_includes development["csp"], "script-src 'self' http://localhost:4500"
    assert_includes development["csp"], "connect-src 'self' http://localhost:4500"
    assert_match(/default-src 'self'(;|\z)/, development["csp"], "default-src is untouched when specific directives exist")
    assert_includes development["on"]["body"], %( nonce="n0nce")
    assert_includes development["on"]["headers"]["content-security-policy"], "'nonce-n0nce'"
  end

  def test_a_skip_key_pattern_from_config
    facts = self.class.facts("development", "DIALECTO_PROBE_SKIP" => "1")
    keys = segments(facts["on"]["body"]).map(&:key)
    refute_includes keys, "pages.home.title"
    assert_includes keys, "hello"
  end
end
