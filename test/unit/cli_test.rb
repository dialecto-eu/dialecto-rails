require "test_helper"

class CliTest < Minitest::Test
  def setup
    @server = FakeDialecto.new
    @repo = GitFixture.new("config/locales/en.yml" => "en:\n  hello: Hello\n")
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    @server.stop
    @repo.cleanup
  end

  def env(extra = {})
    {"DIALECTO_URL" => @server.url, "DIALECTO_PROJECT" => "12", "DIALECTO_SCAN_TOKEN" => TOKEN,
     "DIALECTO_DEFAULT_BRANCH" => "main"}.merge(extra)
  end

  def run_cli(*argv, env: env())
    sleeper = ->(_seconds) {}
    client = ->(config) { DialectoRails::Scan::Client.new(config, sleeper: sleeper, jitter: -> { 0 }) }
    DialectoRails::Scan::Cli.run(argv, env: env, out: @out, err: @err, root: @repo.root, client: client)
  end

  def test_scan_sends_the_committed_catalogs_and_exits_zero
    @repo.write("config/locales/en.yml", "en:\n  hello: dirty\n")
    assert_equal 0, run_cli("scan")

    posts = @server.requests.select { |r| r.method == "POST" }
    assert_equal 1, posts.length
    body = posts.first.json
    assert_equal "main", body["gitBranch"]
    assert_equal "en:\n  hello: Hello\n", body["templates"].first["content"]
    assert_match(/Scan 1 ingested/, @out.string)
  end

  def test_idempotent_scan_says_so
    @server.answer(200, {scan_id: 1, outcome: "idempotent", skipped: []})
    assert_equal 0, run_cli("scan", "--branch", "main")
    assert_match(/Already scanned/, @out.string)
  end

  def test_skipped_files_are_listed_with_their_message
    @server.answer(201, {scan_id: 2, outcome: "ingested", counts: {created: 1}, skipped: [{path: "config/locales/devise.yml", reason: "no_locale", message: "isn't a translation file"}]})
    run_cli("scan", "--branch", "main")
    assert_match(%r{skipped config/locales/devise.yml: isn't a translation file}, @out.string)
  end

  def test_a_branch_the_project_doesnt_scan_sends_nothing
    @repo.checkout("feature/x", create: true)
    @server.answer(200, {scan_mode: "selected", branch_regex: "^release/", tracked_branches: ["main"]})
    assert_equal 0, run_cli("scan", "--branch", "feature/x", env: env("DIALECTO_DEFAULT_BRANCH" => "main"))
    assert_empty @server.requests.select { |r| r.method == "POST" }
    assert_match(/doesn't scan the branch feature\/x/, @out.string)
  end

  def test_tracked_regex_and_all_branches_are_scanned
    [
      {scan_mode: "selected", branch_regex: "^feature/", tracked_branches: []},
      {scan_mode: "selected", branch_regex: nil, tracked_branches: ["feature/x"]},
      {scan_mode: "all", branch_regex: nil, tracked_branches: []}
    ].each do |settings|
      @server.requests.clear
      @server.answer(200, settings)
      assert_equal 0, run_cli("scan", "--branch", "feature/x", env: env("DIALECTO_DEFAULT_BRANCH" => "main"))
      assert_equal 1, @server.requests.count { |r| r.method == "POST" }, settings.inspect
    end
  end

  def test_the_default_branch_is_always_scanned_without_asking
    run_cli("scan", "--branch", "main", env: env("DIALECTO_DEFAULT_BRANCH" => "main"))
    assert_empty @server.requests.select { |r| r.path.end_with?("scan-config") }
  end

  def test_dry_run_sends_nothing
    assert_equal 0, run_cli("scan", "--dry-run")
    assert_empty @server.requests
    assert_match(/Dry run: 1 catalog files/, @out.string)
  end

  def test_missing_token_and_project_exit_two_naming_the_variable
    assert_equal 2, run_cli("scan", env: env("DIALECTO_SCAN_TOKEN" => ""))
    assert_match(/DIALECTO_SCAN_TOKEN/, @err.string)

    @err.truncate(0)
    assert_equal 2, run_cli("scan", env: env("DIALECTO_PROJECT" => "owner/name"))
    assert_match(/project's number/, @err.string)
  end

  def test_plain_http_to_a_remote_host_is_refused_before_anything_is_sent
    assert_equal 2, run_cli("scan", env: env("DIALECTO_URL" => "http://dialecto.example"))
    assert_match(/unencrypted/, @err.string)
    assert_empty @server.requests
  end

  def test_not_a_git_repository_exits_two
    Dir.mktmpdir do |dir|
      code = DialectoRails::Scan::Cli.run(["scan"], env: env, out: @out, err: @err, root: dir)
      assert_equal 2, code
      assert_match(/isn't inside a git repository/, @err.string)
    end
  end

  def test_server_refusal_exits_three_and_retryable_exits_four
    @server.answer(200, {scan_mode: "all"})
    @server.answer(401, {error: "token_invalid", message: "Rotate the token."})
    assert_equal 3, run_cli("scan", "--branch", "x")
    assert_match(/Rotate the token/, @err.string)

    @server.requests.clear
    @server.answer(200, {scan_mode: "all"})
    4.times { @server.answer(503) }
    assert_equal 4, run_cli("scan", "--branch", "x")
  end

  def test_the_token_is_never_printed
    @server.answer(200, {scan_mode: "all"})
    @server.answer(401, {error: "token_invalid", message: "Rotate the token."})
    run_cli("scan", "--branch", "x")
    run_cli("doctor")
    refute_includes @out.string + @err.string, TOKEN
  end

  # A scanner that fails the way a parser bug would.
  module FailingScanner
    def call = Thread.current[:fail_scan] ? raise("boom") : super
  end

  require "dialecto_rails/usages/scanner"
  DialectoRails::Usages::Scanner.prepend(FailingScanner)

  def with_failing_scanner
    Thread.current[:fail_scan] = true
    yield
  ensure
    Thread.current[:fail_scan] = false
  end

  def test_usages_scan_sends_the_usage_records_with_the_catalogs
    @repo.commit("app/views/home/index.html.erb" => "<%= t(\"hello\") %>\n")
    assert_equal 0, run_cli("scan", "--usages", "--branch", "main", env: env("DIALECTO_DEFAULT_BRANCH" => "main"))
    usages = @server.requests.last.json.fetch("railsUsages")
    assert_equal "hello", usages["usages"].first["key"]
  end

  def test_worktree_sends_uncommitted_bytes_and_says_so
    @repo.write("config/locales/en.yml", "en:\n  hello: dirty\n")
    assert_equal 0, run_cli("scan", "--worktree")
    body = @server.requests.select { |r| r.method == "POST" }.last.json
    assert_equal "en:\n  hello: dirty\n", body["templates"].first["content"]
    assert_match(/Reading the working tree/, @err.string)
    committed = @server.requests.size
    @repo.write("config/locales/en.yml", "en:\n  hello: dirtier\n")
    run_cli("scan", "--worktree")
    checksums = @server.requests.select { |r| r.method == "POST" }.map { |r| r.json["checksum"] }
    assert_equal 2, checksums.uniq.length, "a changed file is a new scan"
    assert_operator @server.requests.size, :>, committed
  end

  def test_a_failing_usage_scan_warns_and_still_sends_the_catalogs
    with_failing_scanner do
      assert_equal 0, run_cli("scan", "--usages", "--branch", "main", env: env("DIALECTO_DEFAULT_BRANCH" => "main"))
    end
    assert_match(/without call sites/, @err.string)
    refute @server.requests.last.json.key?("railsUsages")
  end

  def test_require_usages_turns_a_failing_scan_into_exit_two
    with_failing_scanner do
      assert_equal 2, run_cli("scan", "--usages", "--require-usages", "--branch", "main")
    end
    assert_empty @server.requests.select { |r| r.method == "POST" }
  end

  def test_doctor_reports_each_check_and_exits_zero_when_all_pass
    @repo.git("remote", "add", "origin", "https://github.com/acme/shop.git")
    code = run_cli("doctor")
    assert_equal 0, code, @out.string
    assert_match(/ok   catalog files at HEAD/, @out.string)
    assert_match(/ok   Dialecto accepts the token/, @out.string)
  end

  def test_doctor_warns_about_several_workers_without_failing
    @repo.git("remote", "add", "origin", "https://github.com/acme/shop.git")
    run_cli("doctor", env: env("WEB_CONCURRENCY" => "3"))
    assert_match(/warn WEB_CONCURRENCY=3/, @out.string)
    @out.truncate(0)
    @out.rewind
    run_cli("doctor", env: env("WEB_CONCURRENCY" => "1"))
    refute_match(/WEB_CONCURRENCY/, @out.string)
  end

  def test_usages_prints_the_summary_and_writes_the_envelope
    @repo.commit("app/views/home/index.html.erb" => "<%= t(\"hello\") %><%= t(\"gone\") %>\n")
    out_file = File.join(@repo.root, "usages.json")
    assert_equal 0, run_cli("usages", "--out", out_file)
    assert_match(/2 static/, @out.string)
    assert_match(/1 alone/, @out.string)
    assert_equal 2, JSON.parse(File.read(out_file))["usages"].length
  end

  def test_usages_worktree_reads_the_folder_as_it_is_without_a_commit
    @repo.write("app/views/home/index.html.erb", "<%= t(\"hello\") %><%= t(\"dirty\") %>\n")
    out_file = File.join(@repo.root, "usages.json")
    assert_equal 0, run_cli("usages", "--worktree", "--out", out_file)
    assert_equal %w[dirty hello], JSON.parse(File.read(out_file))["usages"].map { |usage| usage["key"] }.sort
  end

  def test_usages_worktree_needs_no_git_repository
    folder = Dir.mktmpdir("dialecto-rails-plain")
    File.write(File.join(folder, "a.rb"), "I18n.t(\"x\")\n")
    out_file = File.join(folder, "usages.json")
    code = DialectoRails::Scan::Cli.run(["usages", "--worktree", "--out", out_file], env: env, out: @out, err: @err,
      root: folder)
    assert_equal 0, code
    assert_equal ["x"], JSON.parse(File.read(out_file))["usages"].map { |usage| usage["key"] }
  ensure
    FileUtils.rm_rf(folder)
  end

  def run_parse_check(paths)
    DialectoRails::Scan::Cli.run(["parse-check"], env: env, out: @out, err: @err, root: @repo.root,
      input: StringIO.new(paths.join("\n")))
  end

  def test_parse_check_passes_readable_files_and_names_the_broken_one
    @repo.write("ok.rb", "I18n.t(\"a\")\n")
    @repo.write("ok.html.erb", "<h1><%= t(\"a\") %></h1>\n<%= yield %>\n")
    @repo.write("broken.rb", "I18n.t(\"a\"\n")
    @repo.write("note.txt", "not code\n")

    assert_equal 0, run_parse_check(%w[ok.rb ok.html.erb note.txt])
    assert_match(/checked 2, skipped 1, failed 0/, @out.string)

    @out.truncate(0)
    @out.rewind
    assert_equal 1, run_parse_check(%w[ok.rb broken.rb])
    assert_match(%r{FAIL broken.rb:1 }, @out.string)
    assert_match(/failed 1/, @out.string)
  end

  def test_check_fails_on_a_key_no_catalog_has_and_names_the_line
    @repo.commit("app/views/home/index.html.erb" => "<%= t(\"hello\") %>\n<%= t(\"gone\") %>\n")
    assert_equal 1, run_cli("check")
    assert_match(%r{error app/views/home/index.html.erb:2 missing_key}, @out.string)
    refute_match(/index.html.erb:1 /, @out.string)
  end

  def test_check_passes_when_every_key_exists_and_treats_test_files_as_warnings
    @repo.commit("app/views/home/index.html.erb" => "<%= t(\"hello\") %>\n", "test/x_test.rb" => "I18n.t(\"nope\")\n")
    assert_equal 0, run_cli("check")
    assert_match(/warning test\/x_test.rb:1 missing_key/, @out.string)
  end

  def test_doctor_names_the_fix_for_a_failure
    assert_equal 2, run_cli("doctor", env: env("DIALECTO_SCAN_TOKEN" => "dlk_short"))
    assert_match(/FAIL scan token shape/, @out.string)
    assert_match(/FAIL origin remote/, @out.string)
  end

  def test_version_and_help_and_unknown
    assert_equal 0, run_cli("version")
    assert_match(/dialecto-rails #{DialectoRails::VERSION}/, @out.string)
    assert_equal 0, run_cli("help")
    assert_equal 2, run_cli("frobnicate")
  end
end
