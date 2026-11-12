require "test_helper"
require "tmpdir"
require "fileutils"
require "i18n"
require "dialecto_rails/in_context/runtime"

class InContextMarkingTest < Minitest::Test
  InContext = DialectoRails::InContext
  Marker = InContext::Marker

  class Backend < ::I18n::Backend::Simple; end

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
      date:
        formats:
          default: "%Y-%m-%d"
      link:
        url: /somewhere
  YAML
  ES = <<~YAML
    es:
      hello: Hola
      inbox:
        messages:
          one: "%{count} mensaje"
          other: "%{count} mensajes"
  YAML

  def setup
    @root = Dir.mktmpdir("dialecto-rails-ctx")
    write("config/locales/en.yml", EN)
    write("config/locales/es.yml", ES)
    write("config/locales/models/user.en.yml", "en:\n  models:\n    user: User\n")
    @outside = Dir.mktmpdir("dialecto-rails-gem")
    File.write(File.join(@outside, "gem.en.yml"), "en:\n  from_gem: From a gem\n")
    @enforce = ::I18n.enforce_available_locales
    ::I18n.enforce_available_locales = false
    @saved = [::I18n.backend, ::I18n.load_path.dup, ::I18n.locale, ::I18n.default_locale]
    ::I18n.backend = Backend.new
    ::I18n.load_path = Dir[File.join(@root, "config/locales/**/*.yml")].sort + [File.join(@outside, "gem.en.yml")]
    ::I18n.default_locale = :en
    ::I18n.locale = :en
    @config = DialectoRails::Config.new({skip_keys: ["pages.skipme", /\.secret\z/]}, {})
    @runtime = InContext::Runtime.new(root: @root, config: @config)
    @runtime.install_hook
  end

  def teardown
    InContext::BackendHook.marking = nil
    ::I18n.backend, ::I18n.load_path, ::I18n.locale, ::I18n.default_locale = @saved
    ::I18n.enforce_available_locales = @enforce
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(@outside)
  end

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def marking_on = @runtime.store.set_marking(true)

  def segment(text) = Marker.parse(text).first

  def test_nothing_is_marked_until_the_editor_turns_marking_on
    assert_equal "Hello", ::I18n.t("hello")
  end

  def test_marks_identity_and_keeps_the_text
    marking_on
    result = ::I18n.t("hello")
    found = segment(result)
    assert_equal ["en.yml", "hello", "en", "Hello"], [found.domain, found.key, found.locale, found.text]
    assert_equal "Hello", Marker.strip(result)
  end

  def test_the_domain_is_the_path_below_config_locales
    marking_on
    assert_equal "models/user.en.yml", segment(::I18n.t("models.user")).domain
  end

  def test_scope_is_expanded_into_the_absolute_key
    marking_on
    assert_equal "pages.home.title", segment(::I18n.t("title", scope: "pages.home")).key
    assert_equal "pages.home.title", segment(::I18n.t("title", scope: %i[pages home])).key
  end

  def test_interpolation_values_are_recorded_and_the_text_is_interpolated
    marking_on
    result = ::I18n.t("greet", name: "Ana")
    assert_equal "Hi Ana", Marker.strip(result)
    assert_equal({"name" => "Ana"}, segment(result).args)
  end

  def test_a_marked_interpolation_value_is_recorded_clean
    marking_on
    inner = ::I18n.t("hello")
    args = segment(::I18n.t("greet", name: inner)).args
    assert_equal({"$marked" => "Hello"}, args["name"])
  end

  def test_a_plural_is_marked_at_its_root_with_the_chosen_form
    marking_on
    one = segment(::I18n.t("inbox.messages", count: 1))
    other = segment(::I18n.t("inbox.messages", count: 5))
    assert_equal "inbox.messages", one.key
    assert_equal [0, 1], [one.args["__form"], other.args["__form"]]
    assert_equal [1, 5], [one.args["__n"], other.args["__n"]]
    assert_equal "5 messages", other.text
  end

  def test_an_html_key_records_the_flag
    marking_on
    assert_equal true, segment(::I18n.t("banner_html")).args["__html"]
  end

  def test_a_fallback_is_marked_with_the_locale_that_supplied_it
    marking_on
    marking = InContext::Marking.new(store: @runtime.store, index: @runtime.index, fallbacks: ->(_locale) { [:en] })
    found = segment(marking.call(:es, "only_english", {}, "English only", nil))
    assert_equal "en", found.locale
    assert_equal "es", segment(marking.call(:es, "hello", {}, "Hola", nil)).locale
  end

  def test_text_the_project_does_not_hold_is_not_marked
    marking_on
    assert_equal "From a gem", ::I18n.t("from_gem")
    assert_equal "Fallback", ::I18n.t("nope.nothing", default: "Fallback")
    assert_match(/translation missing/i, ::I18n.t("nope.missing"))
  end

  def test_data_keys_are_never_marked
    marking_on
    assert_equal "%Y-%m-%d", ::I18n.t("date.formats.default")
    assert_equal "/somewhere", ::I18n.t("link.url")
  end

  def test_the_teams_skip_keys_are_honoured
    write("config/locales/skip.en.yml", "en:\n  pages:\n    skipme: Skip\n    deep:\n      secret: Hush\n")
    ::I18n.backend.reload!
    ::I18n.load_path << File.join(@root, "config/locales/skip.en.yml")
    marking_on
    assert_equal "Skip", ::I18n.t("pages.skipme")
    assert_equal "Hush", ::I18n.t("pages.deep.secret")
  end

  def test_structures_and_arrays_are_returned_untouched
    marking_on
    assert_kind_of Hash, ::I18n.t("pages")
    assert_equal ["Hello"].first, Marker.strip(::I18n.t(["hello"]).first.to_s)
  end

  def test_an_already_marked_result_is_not_marked_twice
    marking_on
    once = ::I18n.t("hello")
    marking = @runtime.marking
    assert_same once, marking.call(:en, "hello", {}, once, nil)
  end

  def test_a_default_chain_is_marked_by_the_key_that_resolved
    marking_on
    result = ::I18n.t("nope.first", default: :hello)
    assert_equal ["hello"], Marker.parse(result).map(&:key)
  end

  def test_a_draft_replaces_the_text_and_is_interpolated
    marking_on
    @runtime.store.replace_overrides([{domain: "en.yml", key: "greet", locale: "en", override: {to: "Yo %{name}"}}])
    result = ::I18n.t("greet", name: "Ana")
    assert_equal "Yo Ana", Marker.strip(result)
    @runtime.store.replace_overrides([])
    assert_equal "Hi Ana", Marker.strip(::I18n.t("greet", name: "Ana"))
  end

  def test_a_plural_draft_picks_the_form_the_way_rails_chose_it
    marking_on
    forms = ["%{count} draft message", "%{count} draft messages"]
    @runtime.store.replace_overrides([{domain: "en.yml", key: "inbox.messages", locale: "en", override: {forms: forms}}])
    assert_equal "1 draft message", Marker.strip(::I18n.t("inbox.messages", count: 1))
    assert_equal "7 draft messages", Marker.strip(::I18n.t("inbox.messages", count: 7))
  end

  def test_a_draft_with_wrong_placeholders_does_not_raise
    marking_on
    @runtime.store.replace_overrides([{domain: "en.yml", key: "hello", locale: "en", override: {to: "Hi %{missing}"}}])
    assert_kind_of String, ::I18n.t("hello")
  end

  EVIL = "<script>alert(1)</script><b>ok</b>".freeze

  def draft_for(key, sanitizer:, result: "<b>Welcome</b>")
    marking = InContext::Marking.new(store: @runtime.store, index: @runtime.index, sanitizer: sanitizer)
    marking_on
    @runtime.store.replace_overrides([{domain: "en.yml", key: key, locale: "en", override: {to: EVIL}}])
    Marker.strip(marking.call(:en, key, {}, result, nil))
  end

  def test_an_html_draft_goes_through_the_sanitizer
    require "rails-html-sanitizer"
    sanitizer = Rails::HTML5::SafeListSanitizer.new
    cleaned = draft_for("banner_html", sanitizer: ->(text) { sanitizer.sanitize(text) })
    assert_includes cleaned, "<b>ok</b>"
    refute_includes cleaned, "<script"
  end

  def test_an_html_draft_is_escaped_when_there_is_no_sanitizer
    escaped = draft_for("banner_html", sanitizer: nil)
    assert_equal "&lt;script&gt;alert(1)&lt;/script&gt;&lt;b&gt;ok&lt;/b&gt;", escaped
  end

  def test_a_draft_for_an_html_safe_result_is_cleaned_even_on_a_plain_key
    safe = Class.new(String) { def html_safe? = true }.new("Hello")
    escaped = draft_for("hello", sanitizer: nil, result: safe)
    refute_includes escaped, "<script"
  end

  def test_a_failing_sanitizer_falls_back_to_escaping
    escaped = draft_for("banner_html", sanitizer: ->(_text) { raise "boom" })
    refute_includes escaped, "<script"
  end

  def test_a_draft_for_a_plain_key_is_left_to_the_template_engine_to_escape
    assert_equal EVIL, draft_for("hello", sanitizer: nil, result: "Hello")
  end

  def test_the_hook_never_raises_into_the_app
    exploding = Object.new
    def exploding.call(*) = raise("boom")
    InContext::BackendHook.marking = exploding
    assert_equal "Hello", ::I18n.t("hello")
  end

  def test_the_index_follows_file_changes
    marking_on
    assert_equal "Hello", Marker.strip(::I18n.t("hello"))
    write("config/locales/extra.en.yml", "en:\n  fresh: Fresh\n")
    ::I18n.load_path << File.join(@root, "config/locales/extra.en.yml")
    ::I18n.backend.reload!
    tick = 10_000
    index = InContext::KeyIndex.new(root: @root, catalog_paths: @config.catalog_paths, clock: -> { tick })
    assert_equal "extra.en.yml", index.domain("en", "fresh")
    assert_nil index.domain("en", "absent")
  end

  def test_a_project_reached_through_a_symlink_still_matches_the_load_path
    link = File.join(Dir.mktmpdir("dialecto-rails-link"), "app")
    File.symlink(@root, link)
    index = InContext::KeyIndex.new(root: link, catalog_paths: @config.catalog_paths,
      load_path: -> { [File.join(@root, "config/locales/en.yml")] })
    assert_equal "en.yml", index.domain("en", "hello")
    index = InContext::KeyIndex.new(root: @root, catalog_paths: @config.catalog_paths,
      load_path: -> { [File.join(link, "config/locales/en.yml")] })
    assert_equal "en.yml", index.domain("en", "hello")
  ensure
    FileUtils.remove_entry(File.dirname(link)) if link
  end

  def test_the_hook_goes_on_the_backend_class_and_only_once
    assert_equal 1, Backend.ancestors.count(InContext::BackendHook)
    @runtime.install_hook
    assert_equal 1, Backend.ancestors.count(InContext::BackendHook)
    refute_includes ::I18n::Backend::Simple.ancestors, InContext::BackendHook
  end

  def test_a_non_file_backend_gets_no_hook
    klass = Class.new { include ::I18n::Backend::Base }
    assert_empty @runtime.install_hook(klass.new)
  end

  def test_the_index_ignores_yaml_tags_and_reads_quoted_keys_and_aliases
    write("config/locales/odd.en.yml", <<~YAML)
      en:
        base: &base
          one: One
        "quoted.key": Q
        derived:
          <<: *base
          two: Two
        tagged: !ruby/object:Object {}
    YAML
    index = InContext::KeyIndex.new(root: @root, catalog_paths: @config.catalog_paths, load_path: -> { [File.join(@root, "config/locales/odd.en.yml")] })
    assert_equal "odd.en.yml", index.domain("en", "base.one")
    assert_equal "odd.en.yml", index.domain("en", "derived.two")
    assert_nil index.domain("en", "derived.one")
    assert_equal "odd.en.yml", index.domain("en", "tagged")
  end
end
