require "../../spec_helper"
require "http/server"
require "socket"

private record Seen, method : String, target : String, headers : HTTP::Headers, body : String

# A real HTTP server on a local port, answering 201 with a JSON body and
# recording what it received.
private def with_server(& : String, Array(Seen) ->) : Nil
  seen = [] of Seen
  server = HTTP::Server.new do |context|
    request = context.request
    seen << Seen.new(request.method, request.resource, request.headers, request.body.try(&.gets_to_end) || "")
    context.response.status_code = 201
    context.response.headers["X-Served-By"] = "spec"
    context.response.print %({"ok": true})
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}", seen
  ensure
    server.close
  end
end

# Reads one request with a Content-Length body off a raw connection.
private def read_request(client : TCPSocket) : String
  length = 0
  first = client.gets || ""
  while (line = client.gets) && !line.empty?
    length = line.split(':', 2)[1].strip.to_i if line.downcase.starts_with?("content-length:")
  end
  client.read_fully(Bytes.new(length)) if length > 0
  first
end

describe Crystalreleaser::Github::HttpTransport do
  it "sends the method, the path with its query, the headers and a text body" do
    with_server do |base, seen|
      headers = HTTP::Headers{"Authorization" => "Bearer secret", "Content-Type" => "application/json"}
      response = Crystalreleaser::Github::HttpTransport.new.request("PATCH", "#{base}/repos/o/r/releases/7?x=a+b", headers, %({"draft": false}))

      response.status.should eq(201)
      response.headers["X-Served-By"].should eq("spec")
      response.body.should eq(%({"ok": true}))
      seen.size.should eq(1)
      request = seen.first
      {request.method, request.target, request.body}.should eq({"PATCH", "/repos/o/r/releases/7?x=a+b", %({"draft": false})})
      request.headers["Authorization"].should eq("Bearer secret")
      request.headers["Content-Length"].should eq("16")
    end
  end

  it "sends a request without a body" do
    with_server do |base, seen|
      Crystalreleaser::Github::HttpTransport.new.request("GET", "#{base}/repos/o/r", HTTP::Headers.new, nil).status.should eq(201)
      {seen.first.method, seen.first.target, seen.first.body}.should eq({"GET", "/repos/o/r", ""})
    end
  end

  it "streams an IO body with the length the caller gave" do
    with_server do |base, seen|
      body = IO::Memory.new("x" * 300_000)
      headers = HTTP::Headers{"Content-Type" => "application/octet-stream", "Content-Length" => "300000"}
      Crystalreleaser::Github::HttpTransport.new.request("POST", "#{base}/upload?name=a.tar.gz", headers, body)

      seen.first.body.bytesize.should eq(300_000)
      seen.first.headers["Content-Length"].should eq("300000")
      seen.first.headers["Transfer-Encoding"]?.should be_nil
    end
  end

  # The server reads the whole request and closes without answering, as when
  # a connection is cut after GitHub got the request. The stdlib client would
  # send it a second time on its own: the transport must report the error and
  # leave the decision to the client, which counts its attempts.
  {"a text body" => %({"tag_name": "v1"}), "a streamed body" => IO::Memory.new("archive bytes")}.each do |kind, body|
    it "never sends a request with #{kind} twice by itself" do
      server = TCPServer.new("127.0.0.1", 0)
      received = [] of String
      spawn do
        2.times do |index|
          client = server.accept? || break
          received << read_request(client)
          client << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}" if index == 1
          client.close
        end
      end
      begin
        headers = HTTP::Headers{"Content-Length" => "13"}
        headers = HTTP::Headers{"Content-Type" => "application/json"} if body.is_a?(String)
        expect_raises(IO::Error) do
          Crystalreleaser::Github::HttpTransport.new.request("POST", "http://127.0.0.1:#{server.local_address.port}/releases", headers, body)
        end
        received.should eq(["POST /releases HTTP/1.1"])
      ensure
        server.close
      end
    end
  end
end
