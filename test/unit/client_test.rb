require "test_helper"

class ClientTest < Minitest::Test
  def setup
    @server = FakeDialecto.new
    @sleeps = []
    @config = DialectoRails::Config.new({url: @server.url, project: 12}, "DIALECTO_SCAN_TOKEN" => TOKEN)
  end

  def teardown = @server.stop

  def client = DialectoRails::Scan::Client.new(@config, sleeper: ->(seconds) { @sleeps << seconds }, jitter: -> { 0 })

  def test_posts_json_under_the_bearer_token
    answer = client.post_scan('{"gitSha":"x"}')
    request = @server.requests.last

    assert_equal "POST", request.method
    assert_equal "/api/repos/12/scans", request.path
    assert_equal "Bearer #{TOKEN}", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]
    assert_equal({"gitSha" => "x"}, request.json)
    assert_equal 201, answer["status"]
    assert_equal "ingested", answer["outcome"]
  end

  def test_idempotent_answer_is_a_success
    @server.answer(200, {scan_id: 4, outcome: "idempotent", skipped: []})
    assert_equal "idempotent", client.post_scan("{}")["outcome"]
  end

  def test_a_redirect_is_refused_with_where_it_points_not_taken_for_an_ingest
    @server.answer(301, "", {"Location" => "https://app.dialecto.eu/api/repos/12/scans"})
    error = assert_raises(DialectoRails::RefusedError) { client.post_scan("{}") }
    assert_equal "HTTP 301 to https://app.dialecto.eu/api/repos/12/scans: check DIALECTO_URL", error.message
    assert_equal 1, @server.requests.size
  end

  def test_scan_config_is_a_get
    answer = client.scan_config
    assert_equal "GET", @server.requests.last.method
    assert_equal "/api/repos/12/scan-config", @server.requests.last.path
    assert_equal "selected", answer["scan_mode"]
  end

  def test_each_auth_refusal_is_refused_with_the_servers_words
    {401 => "token_invalid", 403 => "wrong_project"}.each do |status, code|
      @server.answer(status, {error: code, message: "Fix the pipeline."})
      error = assert_raises(DialectoRails::RefusedError) { client.post_scan("{}") }
      assert_equal "Fix the pipeline. (#{code})", error.message
      assert_equal 3, error.exit_code
    end
  end

  def test_not_entitled_413_and_422_are_refused_without_retry
    @server.answer(403, {error: "not_entitled", message: "Rails is off."})
    @server.answer(413, "too big")
    @server.answer(422, {error: "config/database.yml is outside this project's translation file paths"})
    3.times { assert_raises(DialectoRails::RefusedError) { client.post_scan("{}") } }
    assert_equal 3, @server.requests.length
    assert_empty @sleeps
  end

  def test_retries_5xx_then_succeeds
    @server.answer(503).answer(500)
    answer = client.post_scan("{}")
    assert_equal 201, answer["status"]
    assert_equal 3, @server.requests.length
    assert_equal [1, 4], @sleeps
  end

  def test_gives_up_after_three_retries_with_exit_code_four
    4.times { @server.answer(502) }
    error = assert_raises(DialectoRails::RetryableError) { client.post_scan("{}") }
    assert_equal 4, error.exit_code
    assert_equal 4, @server.requests.length
    assert_equal [1, 4, 16], @sleeps
  end

  def test_429_honours_retry_after_up_to_a_minute
    @server.answer(429, {}, "Retry-After" => "30").answer(429, {}, "Retry-After" => "9999")
    client.post_scan("{}")
    assert_equal [30, 60], @sleeps.map(&:to_i)
  end

  def test_connection_refused_is_retried_then_retryable
    dead = FakeDialecto.new
    url = dead.url
    dead.stop
    config = DialectoRails::Config.new({url: url, project: 12}, "DIALECTO_SCAN_TOKEN" => TOKEN)
    sleeps = []
    c = DialectoRails::Scan::Client.new(config, sleeper: ->(s) { sleeps << s }, jitter: -> { 0 })
    assert_raises(DialectoRails::RetryableError) { c.post_scan("{}") }
    assert_equal [1, 4, 16], sleeps
  end

  def test_the_token_never_appears_in_an_error
    @server.answer(500)
    3.times { @server.answer(500) }
    error = assert_raises(DialectoRails::RetryableError) { client.post_scan("{}") }
    refute_includes error.message, TOKEN
    refute_includes error.message, "dlk_"
  end
end
