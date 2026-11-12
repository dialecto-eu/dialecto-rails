require "test_helper"
require "yaml"

class ActionTest < Minitest::Test
  ACTION = YAML.safe_load_file(File.expand_path("../../action.yml", __dir__))

  def test_declares_the_inputs_the_cli_reads
    inputs = ACTION["inputs"].keys
    %w[project token url catalog-paths usages require-usages ruby-version version].each { |name| assert_includes inputs, name }
    assert ACTION["inputs"]["project"]["required"]
    assert ACTION["inputs"]["token"]["required"]
  end

  def test_composite_with_the_scan_step_passing_the_token_by_environment_only
    assert_equal "composite", ACTION["runs"]["using"]
    scan = ACTION["runs"]["steps"].find { |step| step["id"] == "scan" }
    assert_equal "${{ inputs.token }}", scan["env"]["DIALECTO_SCAN_TOKEN"]
    assert_equal "dialecto-rails scan", scan["run"]
    refute_includes scan["run"], "token"
  end

  def test_outputs_match_what_the_cli_writes
    assert_equal %w[files outcome scan-id], ACTION["outputs"].keys.sort
  end

  def test_the_cli_writes_github_outputs
    server = FakeDialecto.new
    repo = GitFixture.new("config/locales/en.yml" => "en:\n  a: b\n")
    output = File.join(repo.root, "..", "gh-output-#{Process.pid}")
    env = {"DIALECTO_URL" => server.url, "DIALECTO_PROJECT" => "12", "DIALECTO_SCAN_TOKEN" => TOKEN,
           "DIALECTO_DEFAULT_BRANCH" => "main", "GITHUB_OUTPUT" => output}
    code = DialectoRails::Scan::Cli.run(["scan"], env: env, out: StringIO.new, err: StringIO.new, root: repo.root)

    assert_equal 0, code
    written = File.read(output)
    assert_includes written, "scan-id=1\n"
    assert_includes written, "outcome=ingested\n"
    assert_includes written, "files=1\n"
  ensure
    server&.stop
    repo&.cleanup
    File.delete(output) if output && File.exist?(output)
  end

  def test_a_hostile_answer_adds_no_outputs
    server = FakeDialecto.new
    server.answer(201, {"scan_id" => "1\nscan-id=666", "outcome" => "ingested\r\nfiles=9"})
    repo = GitFixture.new("config/locales/en.yml" => "en:\n  a: b\n")
    output = File.join(repo.root, "..", "gh-output-hostile-#{Process.pid}")
    env = {"DIALECTO_URL" => server.url, "DIALECTO_PROJECT" => "12", "DIALECTO_SCAN_TOKEN" => TOKEN,
           "DIALECTO_DEFAULT_BRANCH" => "main", "GITHUB_OUTPUT" => output}
    DialectoRails::Scan::Cli.run(["scan"], env: env, out: StringIO.new, err: StringIO.new, root: repo.root)

    written = File.read(output)
    refute_includes written, "666"
    refute_includes written, "outcome="
    refute_includes written, "scan-id="
    assert_includes written, "files=1\n"
  ensure
    server&.stop
    repo&.cleanup
    File.delete(output) if output && File.exist?(output)
  end
end
