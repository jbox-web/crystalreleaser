require "http/client"
require "uri"

module Crystalreleaser
  module Github
    record Response, status : Int32, headers : HTTP::Headers, body : String

    # The one seam between crystalreleaser and the network: the client builds
    # requests, a transport carries them. Specs inject a fake that records
    # requests and replays scripted responses, so no spec touches the network.
    abstract class Transport
      abstract def request(method : String, url : String, headers : HTTP::Headers, body : IO | String?) : Response
    end

    # A request body the stdlib client cannot send a second time.
    #
    # HTTP::Client retries a request once on its own after an IO error: it
    # rewinds the body and sends it again, on a new connection. The caller
    # never learns that the first copy may have reached GitHub, which breaks
    # every rule of Client that counts attempts (a POST replayed behind its
    # back, an upload whose leftover is taken for someone else's asset), and
    # doubles the timeouts. Refusing to rewind turns that silent retry into
    # the IO error it was, which Client retries knowingly.
    private class OneShotBody < IO
      def initialize(@io : IO)
      end

      def read(slice : Bytes) : Int32
        @io.read(slice)
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("a request body is read-only")
      end

      def rewind
        raise IO::Error.new("connection lost while the request was being sent")
      end
    end

    # The real transport, on the stdlib HTTP::Client. An IO body is streamed
    # (uploads are never loaded in memory); the caller sets Content-Length.
    class HttpTransport < Transport
      def request(method : String, url : String, headers : HTTP::Headers, body : IO | String?) : Response
        uri = URI.parse(url)
        HTTP::Client.new(uri) do |client|
          client.connect_timeout = 30.seconds
          client.read_timeout = 5.minutes
          # Without it an upload to a stalled connection never ends.
          client.write_timeout = 5.minutes
          response = client.exec(method, uri.request_target, headers, one_shot(headers, body))
          Response.new(response.status_code, response.headers, response.body)
        end
      end

      # A text body is given its length here: the stdlib only sets it for a
      # String, and would send an IO without one in chunks.
      private def one_shot(headers : HTTP::Headers, body : IO | String?) : IO?
        case body
        in IO
          OneShotBody.new(body)
        in String
          headers["Content-Length"] = body.bytesize.to_s
          OneShotBody.new(IO::Memory.new(body))
        in Nil
          nil
        end
      end
    end
  end
end
