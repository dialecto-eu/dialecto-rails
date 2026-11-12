require "test_helper"
require "dialecto_rails/in_context/git_context"
require "dialecto_rails/in_context/csp"

class InContextGitContextTest < Minitest::Test
  GitContext = DialectoRails::InContext::GitContext

  def test_parses_a_github_remote_in_its_common_spellings
    %w[
      https://github.com/acme/shop.git
      https://github.com/acme/shop
      git@github.com:acme/shop.git
      ssh://git@github.com/acme/shop.git
      https://github.com/acme/shop/
    ].each { |remote| assert_equal "acme/shop", GitContext.parse_github_remote(remote), remote }
    ["https://gitlab.com/acme/shop.git", "https://github.com/acme", "nonsense", "", nil, "https://github.com/a/b/c"].each do |remote|
      assert_nil GitContext.parse_github_remote(remote), remote.inspect
    end
  end

  def test_parses_porcelain_z_including_renames
    output = " M config/locales/en.yml\0R  new.yml\0old.yml\0?? config/locales/fr.yml\0"
    assert_equal %w[config/locales/en.yml config/locales/fr.yml new.yml old.yml], GitContext.parse_porcelain_z(output)
    assert_empty GitContext.parse_porcelain_z(nil)
  end

  def test_reads_the_context_from_a_repository_and_caches_it_for_a_second
    repo = GitFixture.new("config/locales/en.yml" => "en:\n  a: A\n")
    repo.git("remote", "add", "origin", "git@github.com:acme/shop.git")
    now = 0.0
    context = GitContext.new(root: repo.root, project: "12", clock: -> { now })
    first = context.read
    assert_equal "acme/shop", first[:repo]
    assert_equal "main", first[:branch]
    assert_equal repo.git("rev-parse", "HEAD").strip, first[:sha]
    assert_equal "12", first[:project]
    assert_match(/\Arails@\d/, first[:addon])
    assert_empty first[:dirty]

    repo.write("config/locales/en.yml", "en:\n  a: Changed\n")
    assert_empty context.read[:dirty], "cached within a second"
    now = 1.5
    assert_equal ["config/locales/en.yml"], context.read[:dirty]
  ensure
    repo&.cleanup
  end

  def test_a_directory_that_is_not_a_repository_only_leaves_fields_empty
    Dir.mktmpdir do |dir|
      info = GitContext.new(root: dir).read
      assert_nil info[:repo]
      assert_nil info[:branch]
      assert_nil info[:sha]
      assert_empty info[:dirty]
    end
  end

  Policy = Struct.new(:directives, keyword_init: false) do
    def method_missing(name, *sources)
      directives[name.to_s.tr("_", "-")] = sources
    end

    def respond_to_missing?(*) = true
  end

  def test_csp_adds_the_origin_to_defined_directives_only
    policy = Policy.new("default-src" => ["'self'"], "script-src" => ["'self'"], "connect-src" => ["'none'"])
    DialectoRails::InContext::Csp.allow(policy, "http://localhost:4500")
    assert_equal ["'self'", "http://localhost:4500"], policy.directives["script-src"]
    assert_equal ["http://localhost:4500"], policy.directives["connect-src"]
    assert_equal ["'self'"], policy.directives["default-src"]
    refute policy.directives.key?("frame-src")
  end

  def test_csp_falls_back_to_default_src_and_is_idempotent
    policy = Policy.new("default-src" => ["'self'"])
    2.times { DialectoRails::InContext::Csp.allow(policy, "http://localhost:4500") }
    assert_equal ["'self'", "http://localhost:4500"], policy.directives["default-src"]
  end

  def test_csp_leaves_an_app_without_a_policy_alone
    assert_nil DialectoRails::InContext::Csp.allow(nil, "http://localhost:4500")
    assert_nil DialectoRails::InContext::Csp.allow(Policy.new({}), "http://localhost:4500")
  end
end
