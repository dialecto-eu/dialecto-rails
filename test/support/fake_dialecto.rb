require "socket"
require "json"

# A small HTTP server answering the scan contract (docs/ingestion-api.md), for the scanner's tests. It
# records every request and answers from a queue of canned responses, then from `default`.
class FakeDialecto
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json = JSON.parse(body)
  end

  attr_reader :requests, :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @queue = []
    @default = ->(request) { default_answer(request) }
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{port}"

  # The next response, in order: `answer(status, body_hash, headers)`.
  def answer(status, body = {}, headers = {})
    @queue << [status, body, headers]
    self
  end

  def stop
    @server.close
    @thread.kill
  end

  private

  def serve
    loop do
      client = @server.accept
      Thread.new(client) { |socket| handle(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(socket)
    request = read_request(socket)
    @requests << request
    status, body, headers = @queue.shift || @default.call(request)
    payload = body.is_a?(String) ? body : JSON.generate(body)
    head = ["HTTP/1.1 #{status} X", "Content-Type: application/json", "Content-Length: #{payload.bytesize}",
      "Connection: close"]
    headers.each { |name, value| head << "#{name}: #{value}" }
    socket.write(head.join("\r\n") + "\r\n\r\n" + payload)
  ensure
    socket.close
  end

  def read_request(socket)
    line = socket.gets.to_s
    method, path, = line.split(" ")
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    Request.new(method: method, path: path, headers: headers, body: length.positive? ? socket.read(length) : "")
  end

  def default_answer(request)
    if request.path.end_with?("/scan-config")
      [200, {scan_mode: "selected", branch_regex: nil, tracked_branches: ["main"]}, {}]
    else
      [201, {scan_id: 1, outcome: "ingested", counts: {created: 2, matched: 0, absent: 0}, skipped: []}, {}]
    end
  end
end
