require "uri"

require "./error"
require "./version_info"

module Crystalreleaser
  # The git facts a release needs, read with the git CLI from `dir`.
  class Git
    # git translates its messages; the ones parsed here must be English
    # whatever the user's locale.
    ENVIRONMENT = {"LC_ALL" => "C", "LANG" => "C"}

    def initialize(@dir : String)
    end

    # Runs git and returns its stdout without the trailing newline. Raises a
    # GitError carrying git's own message on failure.
    def run(*args : String, rest : Array(String) = [] of String) : String
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("git", args.to_a + rest, chdir: @dir, env: ENVIRONMENT, output: output, error: error)
      unless status.success?
        message = error.to_s.strip
        raise GitError.new("#{@dir} is not a git repository") if message.includes?("not a git repository")
        raise GitError.new("git #{args.join(' ')}: #{message}")
      end
      output.to_s.chomp
    rescue File::NotFoundError
      # Process.run raises the same error for a missing working directory.
      raise GitError.new("#{@dir}: no such directory") unless Dir.exists?(@dir)
      raise GitError.new("git is not installed")
    end

    # True when nothing is modified, staged or untracked.
    def clean? : Bool
      status.empty?
    end

    # The one semver tag carried by HEAD. Non-semver tags (`latest`) are
    # ignored; zero or several semver tags are errors, since the version would
    # otherwise be a guess.
    def current_tag : String
      tags = run("tag", "--points-at", "HEAD").lines.reject(&.empty?).sort!
      if tags.empty?
        raise GitError.new("HEAD is not tagged: tag it with a semver version (e.g. v1.0.0) or use --snapshot")
      end
      semver = tags.select { |tag| VersionInfo.parse(tag) }
      raise GitError.new("HEAD carries no semver tag (found: #{tags.join(", ")})") if semver.empty?
      raise GitError.new("HEAD carries several semver tags: #{semver.join(", ")}") if semver.size > 1
      semver.first
    end

    # The closest version tag reachable from the parent of `tag`, or nil
    # when `tag` is the first one (the changelog then starts at the first
    # commit). On a shallow clone that parent is simply not there: answering
    # nil would release a changelog cut down to one commit, hence the error.
    def previous_tag(tag : String) : String?
      closest_version_tag("#{tag}^").tap do |previous|
        if previous.nil? && shallow?
          raise GitError.new("this is a shallow clone: the history before #{tag} is missing, so the previous tag " \
                             "and the changelog cannot be computed; fetch the full history " \
                             "(actions/checkout: fetch-depth: 0)")
        end
      end
    end

    def shallow? : Bool
      run("rev-parse", "--is-shallow-repository") == "true"
    end

    # The closest semver tag reachable from `ref`, `ref` included. Tags that
    # are not versions (`latest`, `nightly`) are excluded one by one until
    # git names a version or runs out of tags.
    private def closest_version_tag(ref : String) : String?
      excluded = [] of String
      loop do
        tag = run("describe", "--tags", "--abbrev=0", rest: excluded.flat_map { |name| ["--exclude", name] } + [ref])
        return tag if VersionInfo.parse(tag)
        excluded << tag
      end
    rescue GitError
      nil
    end

    def commit : String
      run("rev-parse", "HEAD")
    end

    # Fixed length, so the value does not depend on core.abbrev or on the
    # size of the repository.
    def short_commit : String
      run("rev-parse", "--short=7", "HEAD")
    end

    # The current branch, or "HEAD" when detached (typical on CI tag builds).
    def branch : String
      run("rev-parse", "--abbrev-ref", "HEAD")
    end

    def first_commit : String
      # `--`: with a tracked file named HEAD, git cannot tell the revision
      # from the path.
      run("rev-list", "--max-parents=0", "HEAD", "--").lines.last
    end

    # owner/name of the origin remote when it points to github.com, in its
    # SSH (git@github.com:o/r.git) or HTTPS (https://github.com/o/r) form.
    def github_remote : {String, String}?
      url = run("remote", "get-url", "origin")
      host, path =
        if url.includes?("://")
          uri = URI.parse(url)
          {uri.host, uri.path}
        elsif match = url.match(/\A(?:[^@\/]+@)?([^:\/]+):(.+)\z/)
          # The scp-like form: [user@]host:path.
          {match[1], match[2]}
        else
          {nil, ""}
        end
      return unless host == "github.com"
      match = path.match(%r{\A/?([^/]+)/([^/]+?)(?:\.git)?/?\z})
      match ? {match[1], match[2]} : nil
    rescue GitError | URI::Error
      nil
    end

    # Committer time of HEAD: the reproducible timestamp of the release.
    def commit_time : Time
      Time.unix(run("log", "-1", "--format=%ct", "HEAD", "--").to_i64)
    end

    # `git status --porcelain`: one line per modified, staged or untracked
    # path. Untracked files are asked for explicitly: a user's
    # `status.showUntrackedFiles=no` would otherwise make a dirty tree clean.
    def status : String
      run("status", "--porcelain", "--untracked-files=normal")
    end

    # The closest version tag reachable from HEAD, HEAD included, or nil
    # when there is none: the base of a snapshot version.
    def last_tag : String?
      closest_version_tag("HEAD")
    end
  end
end
