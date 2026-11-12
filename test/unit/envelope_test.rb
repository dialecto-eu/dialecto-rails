require "test_helper"

class EnvelopeTest < Minitest::Test
  def setup
    @repo = GitFixture.new(
      "config/locales/en.yml" => "en:\n  hello: Hello\n",
      "config/locales/models/user.es.yml" => "es:\n  hi: Hola\n",
      "config/locales/.hidden/x.yml" => "en:\n  a: b\n",
      "config/database.yml" => "default: x\n",
      "app/models/user.rb" => "class User; end\n"
    )
    @git = DialectoRails::Scan::Git.new(@repo.root)
    @catalogs = DialectoRails::Scan::Catalogs.new(DialectoRails::Config::DEFAULT_CATALOG_PATHS)
    @sha = @git.head_sha
  end

  def teardown = @repo.cleanup

  def build(**opts) = DialectoRails::Scan::Envelope.build(git: @git, catalogs: @catalogs, sha: @sha, branch: "main", **opts)

  def test_sends_only_matching_files_verbatim_from_the_commit
    @repo.write("config/locales/en.yml", "en:\n  hello: dirty\n")
    payload = build.payload

    assert_equal %w[config/locales/en.yml config/locales/models/user.es.yml], payload[:templates].map { |t| t[:path] }
    assert_equal "en:\n  hello: Hello\n", payload[:templates].first[:content]
    assert_equal @sha, payload[:gitSha]
    assert_equal "main", payload[:gitBranch]
    refute payload.key?(:railsUsages)
  end

  def test_bytes_are_verbatim_including_crlf_and_trailing_text
    @repo.commit("config/locales/en.yml" => "en:\r\n  hello: \"Hi\"\r\n")
    @sha = @git.head_sha
    assert_equal "en:\r\n  hello: \"Hi\"\r\n", build.payload[:templates].first[:content]
  end

  def test_checksum_is_stable_and_changes_with_commit_files_branch_and_usages
    first = build.payload[:checksum]
    assert_equal first, build.payload[:checksum]
    assert_match(/\A\h{64}\z/, first)

    refute_equal first, DialectoRails::Scan::Envelope.build(git: @git, catalogs: @catalogs, sha: @sha, branch: "dev").payload[:checksum]

    usages = {"version" => "1.0.0", "usages" => [], "unscanned" => []}
    with_usages = build(usages: usages)
    refute_equal first, with_usages.payload[:checksum]
    assert_equal usages, with_usages.payload[:railsUsages]

    @repo.commit("config/locales/en.yml" => "en:\n  hello: Hello!\n")
    @sha = @git.head_sha
    refute_equal first, build.payload[:checksum]
  end

  def test_no_matching_file_says_what_to_set
    catalogs = DialectoRails::Scan::Catalogs.new(["nope/*.yml"])
    error = assert_raises(DialectoRails::ConfigError) do
      DialectoRails::Scan::Envelope.build(git: @git, catalogs: catalogs, sha: @sha, branch: "main")
    end
    assert_match(/DIALECTO_CATALOG_PATHS/, error.message)
  end

  def test_refuses_more_files_than_the_server_takes
    files = (1..1001).to_h { |i| ["config/locales/f#{i}.yml", "en:\n  a: b\n"] }
    @repo.commit(files)
    @sha = @git.head_sha
    error = assert_raises(DialectoRails::ConfigError) { build }
    assert_match(/1,00\d catalog files match; Dialecto takes 1,000/, error.message)
  end

  def test_refuses_a_file_over_the_per_file_limit
    @repo.commit("config/locales/big.yml" => "en:\n  a: " + ("x" * (5 * 1024 * 1024 + 1)) + "\n")
    @sha = @git.head_sha
    error = assert_raises(DialectoRails::ConfigError) { build }
    assert_match(%r{big.yml is 5.0 MB; Dialecto takes 5 MB a file}, error.message)
  end

  def test_refuses_a_file_that_is_not_utf8
    @repo.commit("config/locales/bad.yml" => "en:\n  a: \xFF\xFE\n".b)
    @sha = @git.head_sha
    error = assert_raises(DialectoRails::ConfigError) { build }
    assert_match(/bad.yml isn't valid UTF-8/, error.message)
  end

  def test_symlinks_are_not_followed
    File.symlink("en.yml", File.join(@repo.root, "config/locales/link.yml"))
    @repo.git("add", "-A")
    @repo.git("commit", "-q", "-m", "link")
    @sha = @git.head_sha
    refute_includes build.payload[:templates].map { |t| t[:path] }, "config/locales/link.yml"
  end
end
