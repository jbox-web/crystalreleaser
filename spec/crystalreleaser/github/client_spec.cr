require "../../spec_helper"

private API = "https://api.github.com/repos/jbox-web/toy"

describe Crystalreleaser::Github::Client do
  it "sends the token, the API version and a user agent" do
    transport = FakeTransport.new { github_response(404) }
    fake_client(transport).release_by_tag("jbox-web", "toy", "v1.0.0").should be_nil

    headers = transport.requests.first.headers
    headers["Authorization"].should eq("Bearer secret")
    headers["Accept"].should eq("application/vnd.github+json")
    headers["X-GitHub-Api-Version"].should eq("2022-11-28")
    headers["User-Agent"].should start_with("crystalreleaser/")
    transport.calls.should eq(["GET #{API}/releases/tags/v1.0.0"])
  end

  it "streams an asset upload with its type and length" do
    Fixture.project do |project|
      project.write("dist/toy.tar.gz", "archive bytes")
      transport = FakeTransport.new { github_response(201, %({"id": 9})) }
      fake_client(transport).upload_asset("jbox-web", "toy", 42_i64, "toy 1.tar.gz", project.path("dist/toy.tar.gz"))

      request = transport.requests.first
      request.url.should eq("https://uploads.github.com/repos/jbox-web/toy/releases/42/assets?name=toy+1.tar.gz")
      request.headers["Content-Type"].should eq("application/octet-stream")
      request.headers["Content-Length"].should eq("13")
      request.body.should eq("archive bytes")
    end
  end

  it "writes a file with base64 content and the sha of the previous version" do
    transport = FakeTransport.new { github_response(200) }
    fake_client(transport).put_file("jbox-web", "homebrew-tap", "Formula/toy.rb", "master", "class Toy\n",
      "Brew formula update for toy version v1.0.0", "abc")

    request = transport.requests.first
    request.method.should eq("PUT")
    request.url.should eq("https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb")
    JSON.parse(request.body).should eq(JSON.parse(
      %({"message": "Brew formula update for toy version v1.0.0", "content": "Y2xhc3MgVG95Cg==", "branch": "master", "sha": "abc"})))
  end

  it "reads the sha of an existing file and nil for a missing one" do
    transport = FakeTransport.new do |request|
      request.url.includes?("exists") ? github_response(200, %({"sha": "f00"})) : github_response(404)
    end
    client = fake_client(transport)
    client.file_sha("o", "r", "exists.rb", "main").should eq("f00")
    client.file_sha("o", "r", "missing.rb", "main").should be_nil
  end

  # The contents API answers with an array for a directory.
  it "says so when the path of a file to push is a directory" do
    transport = FakeTransport.new { github_response(200, %([{"name": "toy.rb", "sha": "f00"}])) }
    expect_raises(Crystalreleaser::GithubError, "https://api.github.com/repos/o/r/contents/Formula?ref=main: not a file (a directory?)") do
      fake_client(transport).file_sha("o", "r", "Formula", "main")
    end
  end

  describe "the message of a failed request" do
    it "adds what GitHub says was wrong with each field" do
      body = <<-JSON
        {"message": "Validation Failed", "errors": [
          {"resource": "Release", "code": "already_exists", "field": "tag_name"},
          {"resource": "Release", "code": "custom", "field": "name", "message": "name is too long"},
          "plain text"]}
        JSON
      transport = FakeTransport.new { github_response(422, body) }
      expect_raises(Crystalreleaser::GithubError,
        "POST https://api.github.com/repos/o/r/releases: HTTP 422: Validation Failed " \
        "(tag_name: already_exists; name: name is too long; plain text)") do
        fake_client(transport).create_release("o", "r", {tag_name: "v1"})
      end
    end

    {"[1, 2]" => "[1, 2]", %("gone") => %("gone"), "null" => "null", "<html>502</html>" => "<html>502</html>"}.each do |body, shown|
      it "keeps the HTTP status when the body is #{body}" do
        transport = FakeTransport.new { github_response(404, body) }
        error = expect_raises(Crystalreleaser::GithubError, "DELETE https://api.github.com/repos/o/r/releases/assets/3: HTTP 404: #{shown}") do
          fake_client(transport).delete_asset("o", "r", 3_i64)
        end
        error.status.should eq(404)
      end
    end
  end

  # checksums.txt, the formula and the registry entry all name the asset as
  # it was asked for.
  it "fails when GitHub stores an asset under another name than the one asked for" do
    Fixture.project do |project|
      project.write("dist/toy+1.tar.gz", "archive bytes")
      transport = FakeTransport.new { github_response(201, %({"id": 9, "name": "toy.1.tar.gz"})) }
      expect_raises(Crystalreleaser::GithubError, "GitHub stored the asset toy+1.tar.gz as toy.1.tar.gz: the checksums and " \
                                                  "everything that links to it would name a file that is not there") do
        fake_client(transport).upload_asset("jbox-web", "toy", 42_i64, "toy+1.tar.gz", project.path("dist/toy+1.tar.gz"))
      end
    end
  end

  describe "#find_release" do
    it "returns the published release of the tag without listing" do
      transport = FakeTransport.new { github_response(200, %({"id": 4})) }
      fake_client(transport).find_release("jbox-web", "toy", "v1.0.0").try(&.["id"]).should eq(4)
      transport.calls.should eq(["GET #{API}/releases/tags/v1.0.0"])
    end

    it "finds a draft, which GitHub does not return by tag" do
      transport = FakeTransport.new do |request|
        if request.url.includes?("/releases/tags/")
          github_response(404)
        else
          github_response(200, %([{"id": 1, "tag_name": "v1.0.0", "draft": false}, {"id": 2, "tag_name": "v1.0.0", "draft": true}]))
        end
      end
      fake_client(transport).find_release("jbox-web", "toy", "v1.0.0").try(&.["id"]).should eq(2)
      transport.calls.should eq(["GET #{API}/releases/tags/v1.0.0", "GET #{API}/releases?per_page=100&page=1"])
    end

    it "returns nil when there is neither" do
      transport = FakeTransport.new { |request| request.url.includes?("/tags/") ? github_response(404) : github_response(200, "[]") }
      fake_client(transport).find_release("jbox-web", "toy", "v1.0.0").should be_nil
    end
  end

  it "removes the empty asset a failed upload attempt left, then uploads again" do
    Fixture.project do |project|
      project.write("dist/toy.tar.gz", "archive bytes")
      uploads = [502, 422, 201]
      transport = FakeTransport.new do |request|
        case request.method
        when "POST" then github_response(uploads.shift, %({"message": "already_exists"}))
        when "GET"  then github_response(200, %([{"id": 8, "name": "other"}, {"id": 9, "name": "toy.tar.gz"}]))
        else             github_response(204, "")
        end
      end
      fake_client(transport).upload_asset("jbox-web", "toy", 42_i64, "toy.tar.gz", project.path("dist/toy.tar.gz"))

      upload = "POST https://uploads.github.com/repos/jbox-web/toy/releases/42/assets?name=toy.tar.gz"
      transport.calls.should eq([upload, upload, "GET #{API}/releases/42/assets?per_page=100&page=1",
                                 "DELETE #{API}/releases/assets/9", upload])
    end
  end

  it "does not touch an existing asset when the very first upload attempt answers 422" do
    Fixture.project do |project|
      project.write("dist/toy.tar.gz", "archive bytes")
      transport = FakeTransport.new { github_response(422, %({"message": "already_exists"})) }
      expect_raises(Crystalreleaser::GithubError, "HTTP 422: already_exists") do
        fake_client(transport).upload_asset("jbox-web", "toy", 42_i64, "toy.tar.gz", project.path("dist/toy.tar.gz"))
      end
      transport.requests.size.should eq(1)
    end
  end

  # A POST whose answer is lost may well have created the release: posting
  # again without looking would leave a second draft for the same tag.
  describe "#create_release, which is not idempotent" do
    it "returns the release a lost answer already created instead of posting again" do
      posts = 0
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"POST", "#{API}/releases"}
          posts += 1
          raise IO::Error.new("connection reset")
        when {"GET", "#{API}/releases/tags/v1.0.0"} then github_response(404)
        else                                             github_response(200, %([{"id": 5, "tag_name": "v1.0.0", "draft": true}]))
        end
      end
      fake_client(transport).create_release("jbox-web", "toy", {tag_name: "v1.0.0"})["id"].should eq(5)
      transport.calls.should eq(["POST #{API}/releases", "GET #{API}/releases/tags/v1.0.0", "GET #{API}/releases?per_page=100&page=1"])
    end

    it "posts again when the failed attempt created nothing" do
      answers = [502, 201]
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"POST", "#{API}/releases"}            then github_response(answers.shift, %({"id": 1}))
        when {"GET", "#{API}/releases/tags/v1.0.0"} then github_response(404)
        else                                             github_response(200, "[]")
        end
      end
      waits = [] of Time::Span
      fake_client(transport, waits).create_release("jbox-web", "toy", {tag_name: "v1.0.0"})["id"].should eq(1)
      transport.calls.should eq(["POST #{API}/releases", "GET #{API}/releases/tags/v1.0.0",
                                 "GET #{API}/releases?per_page=100&page=1", "POST #{API}/releases"])
      waits.should eq([1.second])
    end
  end

  describe "#put_file, replayed after a lost answer" do
    put = "PUT https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb"
    get = "GET https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb?ref=master"

    it "takes a conflict for a success when the file already holds the content" do
      puts = 0
      transport = FakeTransport.new do |request|
        if request.method == "PUT"
          puts += 1
          raise IO::Error.new("connection reset") if puts == 1
          github_response(409, %({"message": "Formula/toy.rb does not match abc"}))
        else
          # GitHub wraps the base64 text at 60 columns.
          github_response(200, {"sha" => "def", "content" => "Y2xhc3Mg\nVG95Cg==\n"}.to_json)
        end
      end
      fake_client(transport).put_file("jbox-web", "homebrew-tap", "Formula/toy.rb", "master", "class Toy\n", "update", "abc")
      transport.calls.should eq([put, put, get])
    end

    it "still fails on a conflict when the file holds something else" do
      puts = 0
      transport = FakeTransport.new do |request|
        if request.method == "PUT"
          puts += 1
          raise IO::Error.new("connection reset") if puts == 1
          github_response(409, %({"message": "Formula/toy.rb does not match abc"}))
        else
          github_response(200, %({"sha": "def", "content": "#{Base64.strict_encode("class Other\n")}"}))
        end
      end
      expect_raises(Crystalreleaser::GithubError, "HTTP 409: Formula/toy.rb does not match abc") do
        fake_client(transport).put_file("jbox-web", "homebrew-tap", "Formula/toy.rb", "master", "class Toy\n", "update", "abc")
      end
    end

    it "does not read the file back for a conflict on the very first attempt" do
      transport = FakeTransport.new { github_response(409, %({"message": "Formula/toy.rb does not match abc"})) }
      expect_raises(Crystalreleaser::GithubError, "HTTP 409: Formula/toy.rb does not match abc") do
        fake_client(transport).put_file("jbox-web", "homebrew-tap", "Formula/toy.rb", "master", "class Toy\n", "update", "abc")
      end
      transport.calls.should eq([put])
    end
  end

  it "lists every asset of a release, page after page" do
    page = ->(from : Int32, count : Int32) { (from...from + count).map { |id| {id: id, name: "a#{id}"} }.to_json }
    transport = FakeTransport.new do |request|
      request.url.ends_with?("page=1") ? github_response(200, page.call(0, 100)) : github_response(200, page.call(100, 3))
    end
    assets = fake_client(transport).list_assets("jbox-web", "toy", 7_i64)

    assets.size.should eq(103)
    assets.last["name"].should eq("a102")
    transport.calls.should eq(["GET #{API}/releases/7/assets?per_page=100&page=1", "GET #{API}/releases/7/assets?per_page=100&page=2"])
  end

  describe "retries" do
    it "retries a 5xx with exponential backoff, then succeeds" do
      answers = [502, 503, 200]
      transport = FakeTransport.new { github_response(answers.shift, %({"id": 1})) }
      waits = [] of Time::Span
      fake_client(transport, waits).update_release("o", "r", 5_i64, {name: "x"})["id"].should eq(1)

      transport.requests.size.should eq(3)
      waits.should eq([1.second, 2.seconds])
    end

    it "gives up after three retries" do
      transport = FakeTransport.new { github_response(500, %({"message": "boom"})) }
      waits = [] of Time::Span
      expect_raises(Crystalreleaser::GithubError, "PATCH https://api.github.com/repos/o/r/releases/5: HTTP 500: boom") do
        fake_client(transport, waits).update_release("o", "r", 5_i64, {name: "x"})
      end
      transport.requests.size.should eq(4)
      waits.should eq([1.second, 2.seconds, 4.seconds])
    end

    it "does not retry a 4xx" do
      transport = FakeTransport.new { github_response(422, %({"message": "Validation Failed"})) }
      expect_raises(Crystalreleaser::GithubError, "HTTP 422: Validation Failed") do
        fake_client(transport).create_release("o", "r", {tag_name: "v1"})
      end
      transport.requests.size.should eq(1)
    end

    it "retries network errors" do
      attempts = 0
      transport = FakeTransport.new do
        attempts += 1
        raise IO::Error.new("connection reset") if attempts == 1
        github_response(200, "[]")
      end
      fake_client(transport).list_assets("o", "r", 1_i64).should be_empty
      attempts.should eq(2)
    end

    it "retries TLS errors, which are not IO errors" do
      attempts = 0
      transport = FakeTransport.new do
        attempts += 1
        raise OpenSSL::Error.new("SSL_read: unexpected eof", true) if attempts == 1
        github_response(200, "[]")
      end
      fake_client(transport).list_assets("o", "r", 1_i64).should be_empty
      attempts.should eq(2)
    end

    it "reports a TLS error that persists as a GithubError" do
      transport = FakeTransport.new { raise OpenSSL::Error.new("handshake failed", true) }
      expect_raises(Crystalreleaser::GithubError, "GET https://api.github.com/repos/o/r/releases/1/assets?per_page=100&page=1: handshake failed") do
        fake_client(transport).list_assets("o", "r", 1_i64)
      end
    end

    it "says how long it waits for a rate limit" do
      answers = [429, 200]
      transport = FakeTransport.new do
        status = answers.shift
        github_response(status, "{}", status == 429 ? HTTP::Headers{"Retry-After" => "7"} : HTTP::Headers.new)
      end
      notices = [] of String
      client = fake_client(transport)
      client.on_wait = ->(message : String) { notices << message; nil }
      client.update_release("o", "r", 5_i64, {name: "x"})
      notices.should eq(["GitHub rate limit: waiting 7 seconds"])
    end

    it "fails rather than waiting more than ten minutes for a rate limit" do
      now = Time.utc(2026, 11, 12)
      headers = HTTP::Headers{"X-RateLimit-Remaining" => "0", "X-RateLimit-Reset" => (now + 55.minutes).to_unix.to_s}
      transport = FakeTransport.new { github_response(403, %({"message": "API rate limit exceeded"}), headers) }
      waits = [] of Time::Span
      expect_raises(Crystalreleaser::GithubError, "HTTP 403: API rate limit exceeded (rate limited for 3300 seconds, more than the 600 this run waits)") do
        fake_client(transport, waits, now).delete_asset("o", "r", 3_i64)
      end
      waits.should be_empty
    end

    it "waits for Retry-After on a 429" do
      answers = [429, 200]
      transport = FakeTransport.new do
        status = answers.shift
        github_response(status, "{}", status == 429 ? HTTP::Headers{"Retry-After" => "7"} : HTTP::Headers.new)
      end
      waits = [] of Time::Span
      fake_client(transport, waits).update_release("o", "r", 5_i64, {name: "x"})
      waits.should eq([7.seconds])
    end

    it "waits until X-RateLimit-Reset on a rate-limited 403" do
      now = Time.utc(2026, 11, 12)
      answers = [403, 200]
      transport = FakeTransport.new do
        status = answers.shift
        headers = status == 403 ? HTTP::Headers{"X-RateLimit-Remaining" => "0", "X-RateLimit-Reset" => (now + 30.seconds).to_unix.to_s} : HTTP::Headers.new
        github_response(status, "{}", headers)
      end
      waits = [] of Time::Span
      fake_client(transport, waits, now).delete_asset("o", "r", 3_i64)
      waits.should eq([30.seconds])
    end

    it "does not retry a plain 403" do
      transport = FakeTransport.new { github_response(403, %({"message": "Resource not accessible"})) }
      expect_raises(Crystalreleaser::GithubError, "HTTP 403: Resource not accessible") do
        fake_client(transport).delete_asset("o", "r", 3_i64)
      end
      transport.requests.size.should eq(1)
    end
  end
end
