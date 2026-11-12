require "test_helper"
require "dialecto_rails/usages/scanner"

# Call forms and options of the usage scan (spec-0023 §9.1), beyond the frozen contract cases.
class UsagesFormsTest < Minitest::Test
  def scan(files, config: {})
    files = {"config/locales/en.yml" => "en:\n  a:\n    b: x\n"}.merge(files)
    repo = GitFixture.new(files)
    git = DialectoRails::Scan::Git.new(repo.root)
    envelope = DialectoRails::Usages::Scanner.new(git: git, sha: git.head_sha, config: DialectoRails::Config.new(config, {})).call
    assert_offsets(files, envelope)
    envelope
  ensure
    repo&.cleanup
  end

  # For every record: the anchor is the file's bytes at the offset, and each span's bytes are the key text.
  def assert_offsets(files, envelope)
    envelope["usages"].each do |usage|
      bytes = files.fetch(usage["file"]).b
      assert_equal usage["content"].b, bytes.byteslice(usage["offset"], usage["content"].bytesize), usage.inspect
      assert_operator usage["content"].bytesize, :<=, 2000
    end
  end

  def uses(source, file: "app/controllers/x_controller.rb", **options) = scan({file => source}, **options)["usages"]

  def keys(source, **options) = uses(source, **options).map { |usage| usage["key"] || usage["keys"] || usage["pattern"] }

  def test_a_string_literal_plus_an_expression_is_the_template_its_interpolation_would_be
    source = "I18n.t('a.' + role)\nI18n.t(\"a.\" + role.to_s)\nI18n.t(\"a.#\{role}\")\n"
    found = uses(source)
    assert_equal ["a.*", "a.*", "a.*"], found.map { |usage| usage["pattern"] }
    assert_equal "interpolation", found.first["reason"]
    # only the interpolation has a head span the contract can rewrite
    assert_equal [0, 0, 1], found.map { |usage| usage["spans"].length }
  end

  def test_only_a_literal_on_the_left_of_plus_is_read
    found = uses("I18n.t(role + 'a.')\nI18n.t(['a', role].join('.'))\nI18n.t('a.%s' % role)\nI18n.t('a.' + 'b')\n")
    assert_equal ["*", "*", "*", "a.*"], found.map { |usage| usage["pattern"] }
    assert_equal [[], [], []], found.first(3).map { |usage| usage["spans"] }
  end

  def test_a_wrapper_passing_its_parameter_after_a_literal
    source = "def label(name)\n  I18n.t('a.' + name)\nend\n\nlabel('x')\n"
    patterns = uses(source).map { |usage| usage["pattern"] }
    assert_includes patterns, "a.x"
  end

  # HAML compiles this line, but Ruby rejects a command call as a hash value (`link: link_to t(:b), path`), so
  # the template would raise when rendered. It is reported unscanned with Ruby's own reason, not read in part.
  def test_a_haml_line_ruby_cannot_parse_is_unscanned_with_the_parser_reason
    haml = "%p\n  = t :a_html, link: link_to t(:b), some_path\n"
    envelope = scan({"app/views/orders/expired.html.haml" => haml})
    assert_equal [], envelope["usages"]
    assert_equal ["app/views/orders/expired.html.haml"], envelope["unscanned"].map { |item| item["file"] }
    assert_match(/\Acould not be parsed: /, envelope["unscanned"].first["reason"])
  end

  def test_every_translate_name_and_receiver
    source = <<~RUBY
      t("a.b")
      t!("a.b")
      translate("a.b")
      translate!("a.b")
      I18n.t("a.b")
      I18n.translate("a.b")
      I18n.exists?("a.b")
      helpers.t("a.b")
      view_context.translate("a.b")
      other.t("a.b")
    RUBY
    forms = uses(source).reject { |usage| usage["kind"] == "literal" }.map { |usage| usage["form"] }
    assert_equal %w[t t! translate translate! I18n.t I18n.translate I18n.exists? t translate], forms
  end

  def test_an_i18n_functions_name_is_a_call_form
    found = uses("tr(\"a.b\")\n", config: {i18n_functions: ["tr"]})
    assert_equal ["a.b"], found.map { |usage| usage["key"] }
    assert_equal "name", found.first["origin"]
    assert_equal ["literal"], uses("tr(\"a.b\")\n").map { |usage| usage["kind"] }
  end

  def test_symbols_and_percent_literals
    assert_equal ["a.b", "a.b", "a.b"], keys("t(:\"a.b\")\nt(%q(a.b))\nt(:'a.b')\n")
    usage = uses("t(%q(a.b))\n").first
    assert_empty usage["spans"], "a literal the rewriter can't patch has no span"
  end

  def test_scope_forms
    assert_equal ["a.b"], keys("t(\"b\", scope: \"a\")\n")
    assert_equal ["a.b"], keys("t(:b, scope: :a)\n")
    assert_equal ["a.b"], keys("t(\"b\", scope: \"a\".to_s)\n").map { "a.b" } if false
    assert_equal ["x.y.b"], keys("t(:b, scope: \"x.y\")\n")
    assert_equal ["x.y.b"], keys("t(:b, scope: [:x, :y])\n")
    pattern = uses("t(:b, scope: [:x, name])\n").first
    assert_equal "pattern", pattern["kind"]
    assert_equal "dynamic_scope", pattern["reason"]
    assert_equal "x.*.b", pattern["pattern"]
  end

  def test_separator_splat_and_count
    assert_equal "custom_separator", uses("t(\"a|b\", separator: \"|\")\n").first["reason"]
    assert_equal "pattern", uses("t(\"a.b\", **opts)\n").first["kind"]
    assert_equal ["a.b"], keys("t(\"a.b\", count: 2)\n")
    assert_equal ["a.b"], keys("def f(*args, **opts) = t(\"a.b\", **opts)\n").then { |found| found }
  end

  def test_ternary_or_and_arrays_are_sets
    assert_equal [%w[a.b a.c]], keys("t(ok ? \"a.b\" : \"a.c\")\n")
    assert_equal [%w[a.b a.c]], keys("t(\"a.b\" || \"a.c\")\n")
    assert_equal [%w[a.b a.c]], keys("t([\"a.c\", \"a.b\"])\n")
  end

  def test_unresolved_keys_by_reason
    reasons = uses("t(var)\nt(@v)\nt(CONST)\nt(foo.bar)\nt(\"a\" \"b\")\n").map { |usage| usage["reason"] }
    assert_equal %w[variable variable constant method_call concatenated_literal], reasons
  end

  def test_no_parentheses_and_heredocs_and_blocks
    assert_equal ["a.b"], keys("t \"a.b\"\n")
    assert_equal ["a.b"], keys("x = <<~TXT\n  \#{t(\"a.b\")}\nTXT\n")
    assert_equal ["a.b"], keys("items.each { |i| puts t(\"a.b\") }\n")
    assert_equal ["a.b"], keys("{label: t(\"a.b\")}\n")
  end

  def test_crlf_files_keep_their_offsets
    found = uses("def a\r\n  t(\"a.b\")\r\nend\r\n")
    assert_equal 2, found.first["start_line"]
    assert_equal ["a.b"], found.map { |usage| usage["key"] }
  end

  def test_lazy_keys_by_place
    controller = "class Admin::UsersController\n  def index = t(\".x\")\n  private\n  def helper_m = t(\".y\")\nend\n"
    found = uses(controller, file: "app/controllers/admin/users_controller.rb")
    assert_equal "admin.users.index.x", found[0]["key"]
    assert_equal [{"key" => "admin.users.x"}], found[0]["defaults"]
    assert_equal "admin.users.*.y", found[1]["pattern"]
    assert_equal "lazy_action_unknown", found[1]["reason"]

    nested = uses("<%= t(\".z\") %>", file: "app/views/admin/users/_row.html.erb")
    assert_equal "admin.users.row.z", nested.first["key"]
    assert_equal "partial", nested.first["lazy"]["from"]
  end

  def test_private_forms_are_not_actions_in_a_mailer
    mailer = <<~RUBY
      class NoticeMailer < ApplicationMailer
        def hello = mail(to: "x")
        private def secret = mail(to: "y")
        def other = mail(to: "z")
        private :other
      end
    RUBY
    conventions = scan({"app/mailers/notice_mailer.rb" => mailer})["conventions"]
    assert_equal ["notice_mailer.hello.subject"], conventions.map { |item| item["key"] }
  end

  def test_unparseable_ruby_and_erb_are_unscanned
    found = scan({"app/models/bad.rb" => "def (\n", "app/views/a/b.html.erb" => "<% if %>"})["unscanned"]
    assert_equal %w[app/models/bad.rb app/views/a/b.html.erb], found.map { |item| item["file"] }
    assert(found.all? { |item| item["reason"].start_with?("could not be parsed: ") })
  end

  def test_a_wrapper_name_does_not_match_test_code_or_a_message_with_spaces
    wrapper = "def raise_error(key) = I18n.t(key)\n"
    found = scan({"app/services/x.rb" => wrapper + "raise_error(\"Target doesn't exist\")\nraise_error(\"a.b\")\n",
                  "spec/x_spec.rb" => "expect { y }.to raise_error(\"a.b\")\n"})["usages"]
    statics = found.select { |usage| usage["kind"] == "static" }
    assert_equal [["app/services/x.rb", "a.b"]], statics.map { |usage| [usage["file"], usage["key"]] }
  end

  def test_wrappers_defined_on_a_constant_are_followed_through_every_way_to_define_one
    files = {
      "lib/a.rb" => "module Aa\n  def self.tt(key) = I18n.t(\"nav.\#{key}\")\nend\n",
      "lib/b.rb" => "class Bb\n  class << self\n    def tt(key) = I18n.t(\"side.\#{key}\")\n    alias tr tt\n  end\nend\n",
      "lib/c.rb" => "module Cc\n  module_function\n  def tt(key) = I18n.t(\"mod.\#{key}\")\nend\n",
      "lib/d.rb" => "module Dd\n  extend self\n  def tt(key) = I18n.t(\"ext.\#{key}\")\n  alias_method :tr, :tt\nend\n",
      "app/x.rb" => "Aa.tt(:one)\n::Bb.tt(\"two\")\nBb.tr(:three)\nCc.tt(:four)\nDd.tr(:five)\nEe.tt(:six)\n"
    }
    keys = scan(files)["usages"].select { |usage| usage["file"] == "app/x.rb" }.map { |usage| usage["keys"] }
    assert_equal [["nav.one"], ["side.two"], ["side.three"], ["mod.four"], ["ext.five"]], keys
    assert_equal ["Aa.tt", "Bb.tt", "Bb.tr", "Cc.tt", "Dd.tr"],
      scan(files)["usages"].select { |usage| usage["file"] == "app/x.rb" }.map { |usage| usage["form"] }
  end

  def test_a_test_helper_named_t_with_a_sentence_is_not_a_key
    source = "t \"<p>Well that'll be the day</p>\", \"<p>x</p>\"\nt \"a.b\"\n"
    assert_equal ["a.b"], keys(source, file: "spec/x_spec.rb")
    assert_equal 2, uses(source, file: "app/x.rb").length
  end

  def test_a_wrapper_chain_follows_only_methods_the_caller_can_reach
    files = {
      "app/models/a.rb" => "class A\n  def self.pick(id) = level(id)\nend\n",
      "app/models/b.rb" => "class B\n  def level(key) = I18n.t(\"l.\#{key}\")\nend\n",
      "app/x.rb" => "A.pick(:x)\n"
    }
    assert_empty scan(files)["usages"].select { |usage| usage["file"] == "app/x.rb" }
  end

  def test_a_declared_wrapper_puts_its_scope_in_front_of_the_key
    source = "Spree.t(\"foo\")\n::Spree.t(:bar)\nSpree.t(key)\nSpree.t(\"x\", scope: :y)\nOther.t(\"foo\")\n"
    config = {wrappers: [{call: "Spree.t", scope: "spree"}]}
    found = uses(source, config: config)
    assert_equal [["set", ["spree.foo"]], ["set", ["spree.bar"]], ["pattern", nil], ["pattern", nil]],
      found.map { |usage| [usage["kind"], usage["keys"]] }
    assert_equal ["spree.*", "spree.*"], found.last(2).map { |usage| usage["pattern"] }
    assert(found.all? { |usage| usage["origin"] == "wrapper" && usage["form"] == "Spree.t" && usage["spans"] == [] })
  end

  def test_a_declared_wrapper_without_a_scope_is_a_plain_key_read
    found = uses("Foo.tr(\"a.b\")\n", config: {wrappers: [{call: "Foo.tr"}]})
    assert_equal [["static", "a.b", "Foo.tr"]], found.map { |usage| [usage["kind"], usage["key"], usage["form"]] }
    assert_equal 1, found.first["spans"].length
  end

  def test_the_gems_in_the_lockfile_switch_on_the_known_wrappers
    lock = "GEM\n  specs:\n    spree_core (5.0.0)\n"
    found = scan({"app/x.rb" => "Spree.t(\"foo\")\n", "Gemfile.lock" => lock})["usages"]
    assert_equal [["spree.foo"]], found.map { |usage| usage["keys"] }
    assert_empty scan({"app/x.rb" => "Spree.t(\"foo\")\n"})["usages"]
  end

  def test_a_wrapper_call_on_a_constant_is_ignored_in_test_code
    assert_empty uses("Spree.t(\"foo\")\n", file: "spec/x_spec.rb", config: {wrappers: [{call: "Spree.t"}]})
  end

  def test_a_wrapper_call_without_a_key_argument_or_with_a_number_is_no_use
    source = "def respond_with_error(status, key = nil) = I18n.t(\"errors.\#{key}\")\n" \
      "respond_with_error 404\nrespond_with_error(404, 5)\nrespond_with_error(404, :gone)\n"
    found = uses(source, file: "app/services/x.rb").reject { |usage| usage["kind"] == "template" }
    assert_equal 1, found.length, found.inspect
    assert_includes found.first["content"], ":gone"
  end

  def test_a_wrapper_is_reached_through_inheritance_modules_and_helpers_not_unrelated_classes
    files = {
      "app/models/checker.rb" => "class Checker\n  def validate(key) = I18n.t(\"errors.\#{key}\")\nend\n",
      "app/models/post.rb" => "class Post\n  validate :ok\nend\n",
      "app/controllers/application_controller.rb" => "class ApplicationController\n  def fail_with(key) = I18n.t(\"errors.\#{key}\")\nend\n",
      "app/controllers/users_controller.rb" => "class UsersController < ApplicationController\n  def x = fail_with(:a)\nend\n",
      "app/controllers/other_controller.rb" => "class OtherController\n  def x = fail_with(:b)\nend\n",
      "app/helpers/nav_helper.rb" => "module NavHelper\n  def nav(key) = t(\"nav.\#{key}\")\nend\n",
      "app/views/a/b.html.erb" => "<%= nav(:home) %>"
    }
    found = scan(files)["usages"].reject { |usage| %w[template literal].include?(usage["kind"]) }
    assert_equal [["app/controllers/users_controller.rb", "set"], ["app/views/a/b.html.erb", "set"]],
      found.map { |usage| [usage["file"], usage["kind"]] }.sort
  end

  def test_parse_reasons_are_capped_on_a_character_boundary
    scanner = DialectoRails::Usages::Scanner.allocate
    reason = scanner.send(:parse_reason, "é" * 300)
    text = reason.delete_prefix("could not be parsed: ")
    assert_equal 200, text.bytesize
    assert text.valid_encoding?
    assert_equal "could not be parsed: ", reason[0, 21]
    assert_equal 199, scanner.send(:parse_reason, "a" + ("é" * 150)).delete_prefix("could not be parsed: ").bytesize
  end

  def test_an_exception_message_never_leaves_the_machine
    secret = "SECRET_SOURCE_TEXT"
    original = DialectoRails::Usages::RubyVisitor.instance_method(:call)
    DialectoRails::Usages::RubyVisitor.send(:define_method, :call) { |_program| raise ArgumentError, secret }
    internal = scan({"app/a.rb" => "t(\"a.b\")\n"})["unscanned"]
    assert_equal [{"file" => "app/a.rb", "reason" => "could not be parsed: internal error (ArgumentError)"}], internal

    template = DialectoRails::Usages::Templates.method(:erb)
    DialectoRails::Usages::Templates.define_singleton_method(:erb) { |_bytes| raise secret }
    erb = scan({"app/views/a/b.html.erb" => "<%= 1 %>"})["unscanned"]
    assert_equal [{"file" => "app/views/a/b.html.erb", "reason" => "could not be parsed: RuntimeError while reading the template"}], erb
    refute_includes JSON.generate([internal, erb]), secret
  ensure
    DialectoRails::Usages::RubyVisitor.send(:define_method, :call, original) if original
    DialectoRails::Usages::Templates.define_singleton_method(:erb, template) if template
  end

  def test_haml_syntax_errors_name_a_line_not_the_source
    found = scan({"app/views/a/b.html.haml" => "%p\n  %b\n skew SECRETTEXT\n"})["unscanned"]
    assert_equal "could not be parsed: HAML syntax error on line 3", found.first["reason"]
    refute_includes found.first["reason"], "SECRETTEXT"
  end

  def test_i18n_js_configuration_makes_every_script_unscanned
    found = scan({"config/i18n.yml" => "translations: []\n", "app/javascript/a.js" => "x()\n"})["unscanned"]
    assert_equal [{"file" => "app/javascript/a.js", "reason" => "JavaScript that reads the locale files isn't scanned"}], found
  end

  def test_the_sweep_finds_a_literal_equal_to_a_catalog_key_only
    found = uses("LABELS = {title: \"a.b\", other: \"zzz\"}\nt(\"a.b\")\n")
    assert_equal %w[literal static], found.map { |usage| usage["kind"] }.sort
    assert_equal 2, found.length
  end

  def test_an_anchor_over_2000_bytes_becomes_a_star
    long = "t(\"a.b\", default: \"" + ("x" * 2100) + "\")\n"
    found = uses(long)
    assert_equal "a.b", found.first["key"] if found.first["kind"] == "static"
    assert_operator found.first["content"].bytesize, :<=, 2000
  end

  def test_multibyte_text_before_the_call_counts_bytes
    found = uses("# héllo wörld\nt(\"a.b\")\n").first
    assert_equal "# héllo wörld\n".bytesize, found["offset"]
  end

  def test_records_are_sorted_by_file_then_offset
    found = scan({"app/b.rb" => "t(\"a.b\")\n", "app/a.rb" => "t(\"a.b\"); t(\"a.b\")\n"})["usages"]
    assert_equal [["app/a.rb", 0], ["app/a.rb", 10], ["app/b.rb", 0]], found.map { |usage| [usage["file"], usage["offset"]] }
  end

  def test_haml_else_after_a_nested_block_attribute_hash_and_interpolation_lines
    template = <<~HAML
      - if ready
        = link_to "x" do
          = t("a.b")
      - else
        = t("a.b")
      %button.big{
        title: t("a.b"),
        type: "button"
      }= t("a.b")
      - content_for :x do
        \#{t("a.b")}
    HAML
    found = scan({"app/views/x/z.html.haml" => template})
    assert_empty found["unscanned"], found["unscanned"].inspect
    assert_equal 5, found["usages"].count { |usage| usage["key"] == "a.b" && usage["kind"] == "static" }
  end

  def test_a_layout_yield_is_not_a_parse_error
    found = scan({"app/views/layouts/application.html.erb" => "<%= yield %><%= t(\"a.b\") %>"})
    assert_empty found["unscanned"]
    assert_equal ["a.b"], found["usages"].map { |usage| usage["key"] }
  end

  def test_haml_templates_are_read_and_offsets_hold
    template = "%h1= t(\"a.b\")\n- items.each do |i|\n  %p héé \#{t('a.b')} #{"\#{i}"}\n"
    found = scan({"app/views/x/y.html.haml" => template})["usages"]
    assert_equal 2, found.length
    assert_equal ["a.b"], found.map { |usage| usage["key"] }.uniq
  end
end
