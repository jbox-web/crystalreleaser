require "base64"
require "json"
require "openssl"
require "uri"

require "../error"
require "../version"
require "./http_transport"

module Crystalreleaser
  # GitHub answered with an error, or could not be reached.
  class GithubError < Error
    getter status : Int32?

    def initialize(message : String, @status : Int32? = nil)
      super(message)
    end
  end

  module Github
    # The few REST calls a release needs: releases, assets, file contents.
    #
    # Retries: up to `max_retries` more attempts, only on 5xx answers and
    # network or TLS errors, with exponential backoff (1s, 2s, 4s). A 403/429
    # that carries `Retry-After` or `X-RateLimit-Reset` is a rate limit: wait
    # as told (never more than MAX_RATE_LIMIT_WAIT, and saying so through
    # `on_wait`), then retry, within the same budget. Every other 4xx fails
    # at once.
    class Client
      API     = "https://api.github.com"
      UPLOADS = "https://uploads.github.com"

      # A rate limit asking for more than this fails the run: a release that
      # sleeps silently for an hour looks hung.
      MAX_RATE_LIMIT_WAIT = 10.minutes

      # Told before each rate-limit wait; the context plugs the logger in.
      property on_wait : Proc(String, Nil)? = nil

      alias Sleeper = Proc(Time::Span, Nil)

      def initialize(@token : String, @transport : Transport = HttpTransport.new,
                     @sleeper : Sleeper = ->(span : Time::Span) { sleep(span) },
                     @clock : Proc(Time) = -> { Time.utc }, @max_retries : Int32 = 3)
      end

      # The release of `tag`, or nil when there is none.
      def release_by_tag(owner : String, repo : String, tag : String) : JSON::Any?
        response = call("GET", "#{API}/repos/#{owner}/#{repo}/releases/tags/#{URI.encode_path_segment(tag)}", allow: {404})
        response.status == 404 ? nil : JSON.parse(response.body)
      end

      # The release of `tag`, draft included. GitHub's lookup by tag only
      # returns published releases, so a draft is searched in the listing:
      # without that, a rerun would pile up one draft per attempt.
      def find_release(owner : String, repo : String, tag : String) : JSON::Any?
        release_by_tag(owner, repo, tag) || draft_release(owner, repo, tag)
      end

      private def draft_release(owner : String, repo : String, tag : String) : JSON::Any?
        page = 1
        loop do
          url = "#{API}/repos/#{owner}/#{repo}/releases?per_page=100&page=#{page}"
          batch = JSON.parse(call("GET", url).body).as_a
          found = batch.find { |release| release["draft"]?.try(&.as_bool?) && release["tag_name"]?.try(&.as_s?) == tag }
          return found if found || batch.size < 100
          page += 1
        end
      end

      # Not idempotent: an attempt whose answer was lost (5xx, connection cut)
      # may have created the release all the same. Before posting again, the
      # release of the tag is looked up, and returned when it is there:
      # without that, a retry leaves a second draft for the same tag.
      def create_release(owner : String, repo : String, payload) : JSON::Any
        url = "#{API}/repos/#{owner}/#{repo}/releases"
        attempts = 0
        response = with_retries("POST", url) do
          attempts += 1
          existing = find_release(owner, repo, payload[:tag_name]) if attempts > 1
          if existing
            Response.new(200, HTTP::Headers.new, existing.to_json)
          else
            @transport.request("POST", url, headers(HTTP::Headers{"Content-Type" => "application/json"}), payload.to_json)
          end
        end
        JSON.parse(response.body)
      end

      def update_release(owner : String, repo : String, id : Int64, payload) : JSON::Any
        JSON.parse(call("PATCH", "#{API}/repos/#{owner}/#{repo}/releases/#{id}", payload.to_json).body)
      end

      def list_assets(owner : String, repo : String, release_id : Int64) : Array(JSON::Any)
        assets = [] of JSON::Any
        page = 1
        loop do
          url = "#{API}/repos/#{owner}/#{repo}/releases/#{release_id}/assets?per_page=100&page=#{page}"
          batch = JSON.parse(call("GET", url).body).as_a
          assets.concat(batch)
          break if batch.size < 100
          page += 1
        end
        assets
      end

      def delete_asset(owner : String, repo : String, asset_id : Int64) : Nil
        call("DELETE", "#{API}/repos/#{owner}/#{repo}/releases/assets/#{asset_id}")
      end

      # Streams `path` to the release; the file is reopened on each attempt.
      #
      # A failed attempt can leave an empty asset behind, and GitHub then
      # answers 422 to the next one: that leftover is deleted and the upload
      # tried again, once. A 422 on the very first attempt is someone else's
      # asset and is never touched.
      def upload_asset(owner : String, repo : String, release_id : Int64, name : String, path : String) : JSON::Any
        url = "#{UPLOADS}/repos/#{owner}/#{repo}/releases/#{release_id}/assets?name=#{URI.encode_www_form(name)}"
        extra = HTTP::Headers{
          "Content-Type"   => "application/octet-stream",
          "Content-Length" => File.size(path).to_s,
        }
        attempts = 0
        upload = -> do
          with_retries("POST", url) do
            attempts += 1
            File.open(path) { |file| @transport.request("POST", url, headers(extra), file) }
          end
        end
        response =
          begin
            upload.call
          rescue error : GithubError
            leftover = leftover_asset(owner, repo, release_id, name) if error.status == 422 && attempts > 1
            raise error unless leftover
            delete_asset(owner, repo, leftover["id"].as_i64)
            upload.call
          end
        asset = JSON.parse(response.body)
        stored = asset["name"]?.try(&.as_s?)
        if stored && stored != name
          raise GithubError.new("GitHub stored the asset #{name} as #{stored}: the checksums and everything that " \
                                "links to it would name a file that is not there")
        end
        asset
      end

      private def leftover_asset(owner : String, repo : String, release_id : Int64, name : String) : JSON::Any?
        list_assets(owner, repo, release_id).find { |asset| asset["name"]?.try(&.as_s?) == name }
      end

      # The blob sha of a file in a repository, or nil when it does not exist.
      def file_sha(owner : String, repo : String, path : String, branch : String) : String?
        url = "#{API}/repos/#{owner}/#{repo}/contents/#{encode_path(path)}?ref=#{URI.encode_www_form(branch)}"
        response = call("GET", url, allow: {404})
        return if response.status == 404
        # An array is the listing of a directory.
        JSON.parse(response.body).as_h?.try(&.["sha"]?).try(&.as_s?) || raise GithubError.new("#{url}: not a file (a directory?)")
      end

      # Creates or updates a file in one commit; `sha` is required by GitHub
      # to update an existing file.
      def put_file(owner : String, repo : String, path : String, branch : String, content : String,
                   message : String, sha : String?) : Nil
        payload = {"message" => message, "content" => Base64.strict_encode(content), "branch" => branch}
        payload["sha"] = sha if sha
        url = "#{API}/repos/#{owner}/#{repo}/contents/#{encode_path(path)}"
        attempts = 0
        begin
          with_retries("PUT", url) do
            attempts += 1
            @transport.request("PUT", url, headers(HTTP::Headers{"Content-Type" => "application/json"}), payload.to_json)
          end
        rescue error : GithubError
          # Not idempotent either: when the answer to a first attempt was
          # lost, the commit may be there, and the attempt that follows is
          # refused because the sha it gives is no longer the file's (409),
          # or because the file it meant to create exists (422). The file
          # then holds what was to be written, and that is a success.
          raise error unless attempts > 1 && error.status.in?(409, 422) && file_content(owner, repo, path, branch) == content
        end
      end

      # The content of a file in a repository, or nil when it does not exist.
      private def file_content(owner : String, repo : String, path : String, branch : String) : String?
        url = "#{API}/repos/#{owner}/#{repo}/contents/#{encode_path(path)}?ref=#{URI.encode_www_form(branch)}"
        response = call("GET", url, allow: {404})
        return if response.status == 404
        # GitHub wraps the base64 text in lines.
        JSON.parse(response.body)["content"]?.try(&.as_s?).try { |text| Base64.decode_string(text.delete('\n')) }
      end

      private def encode_path(path : String) : String
        path.split('/').join('/') { |segment| URI.encode_path_segment(segment) }
      end

      private def call(method : String, url : String, body : String? = nil, allow : Tuple = Tuple.new) : Response
        extra = body ? HTTP::Headers{"Content-Type" => "application/json"} : HTTP::Headers.new
        with_retries(method, url, allow) { @transport.request(method, url, headers(extra), body) }
      end

      private def headers(extra : HTTP::Headers) : HTTP::Headers
        headers = HTTP::Headers{
          "Authorization"        => "Bearer #{@token}",
          "Accept"               => "application/vnd.github+json",
          "X-GitHub-Api-Version" => "2022-11-28",
          "User-Agent"           => "crystalreleaser/#{VERSION}",
        }
        headers.merge!(extra)
      end

      private def with_retries(method : String, url : String, allow : Tuple = Tuple.new, & : -> Response) : Response
        attempt = 0
        loop do
          attempt += 1
          begin
            response = yield
          rescue error : IO::Error | Socket::Error | OpenSSL::Error
            raise GithubError.new("#{method} #{url}: #{error.message}") if attempt > @max_retries
            @sleeper.call(backoff(attempt))
            next
          end

          status = response.status
          return response if status < 300 || allow.includes?(status)

          if wait = rate_limit_wait(response)
            raise failure(method, url, response) if attempt > @max_retries
            if wait > MAX_RATE_LIMIT_WAIT
              raise failure(method, url, response, "rate limited for #{wait.total_seconds.to_i} seconds, " \
                                                   "more than the #{MAX_RATE_LIMIT_WAIT.total_seconds.to_i} this run waits")
            end
            @on_wait.try &.call("GitHub rate limit: waiting #{wait.total_seconds.to_i} seconds")
            @sleeper.call(wait)
          elsif status >= 500
            raise failure(method, url, response) if attempt > @max_retries
            @sleeper.call(backoff(attempt))
          else
            raise failure(method, url, response)
          end
        end
      end

      private def backoff(attempt : Int32) : Time::Span
        (2 ** (attempt - 1)).seconds
      end

      # How long a rate-limited answer asks to wait, or nil when the answer
      # is not a rate limit.
      private def rate_limit_wait(response : Response) : Time::Span?
        return unless response.status.in?(403, 429)
        if retry_after = response.headers["Retry-After"]?.try(&.to_i?)
          return retry_after.seconds
        end
        if response.headers["X-RateLimit-Remaining"]? == "0" || response.status == 429
          if reset = response.headers["X-RateLimit-Reset"]?.try(&.to_i64?)
            return {Time.unix(reset) - @clock.call, Time::Span.zero}.max
          end
        end
        nil
      end

      private def failure(method : String, url : String, response : Response, note : String? = nil) : GithubError
        body =
          begin
            JSON.parse(response.body).as_h?
          rescue JSON::ParseException
            nil
          end
        detail = body.try(&.["message"]?).try(&.as_s?) || response.body
        # A 422 says "Validation Failed" and keeps the reason in `errors`.
        fields = body.try(&.["errors"]?).try(&.as_a?).try(&.map { |error| field_error(error) }.reject(&.empty?)) || [] of String
        notes = [fields.join("; "), note].compact.reject(&.empty?)
        suffix = notes.empty? ? "" : " (#{notes.join("; ")})"
        GithubError.new("#{method} #{url}: HTTP #{response.status}: #{detail.strip}#{suffix}", response.status)
      end

      # One entry of `errors`: `tag_name: already_exists`, or the message
      # GitHub wrote for a custom error.
      private def field_error(error : JSON::Any) : String
        entry = error.as_h? || return error.as_s? || error.to_json
        what = entry["message"]?.try(&.as_s?) || entry["code"]?.try(&.as_s?) || ""
        field = entry["field"]?.try(&.as_s?)
        field ? "#{field}: #{what}" : what
      end
    end
  end
end
