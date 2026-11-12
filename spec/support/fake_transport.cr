# Records every request and answers from a handler, so specs script GitHub
# without any network access.
class FakeTransport < Crystalreleaser::Github::Transport
  record Request, method : String, url : String, headers : HTTP::Headers, body : String

  getter requests = [] of Request

  def initialize(&@handler : Request -> Crystalreleaser::Github::Response)
  end

  def request(method : String, url : String, headers : HTTP::Headers, body : IO | String?) : Crystalreleaser::Github::Response
    text = case body
           in IO     then body.gets_to_end
           in String then body
           in Nil    then ""
           end
    request = Request.new(method, url, headers, text)
    @requests << request
    @handler.call(request)
  end

  def calls : Array(String)
    @requests.map { |request| "#{request.method} #{request.url}" }
  end
end

def github_response(status : Int32, body : String = "{}", headers = HTTP::Headers.new) : Crystalreleaser::Github::Response
  Crystalreleaser::Github::Response.new(status, headers, body)
end

# A client on a fake transport that records the waits instead of sleeping.
def fake_client(transport : FakeTransport, waits : Array(Time::Span) = [] of Time::Span,
                now : Time = Time.utc(2026, 11, 12)) : Crystalreleaser::Github::Client
  Crystalreleaser::Github::Client.new("secret", transport,
    ->(span : Time::Span) { waits << span; nil }, -> { now })
end
