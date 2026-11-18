require "./artifact"
require "./builders/builder"
require "./config"
require "./git"
require "./github/client"
require "./host"
require "./logger"
require "./template"
require "./version_info"

module Crystalreleaser
  # What the command line asked for.
  class Options
    property? snapshot : Bool = false
    property? clean : Bool = false
    property parallelism : Int32 = System.cpu_count.to_i32.clamp(1, nil)
    # Restrict the build to these build ids; empty means all.
    property ids : Array(String) = [] of String
    # Pipe names or groups given with --skip.
    property skip : Array(String) = [] of String
    property release_notes : String? = nil
    # build --split: only some platforms, outputs under dist/<os>_<arch>/.
    property? split : Bool = false
    property split_os : String? = nil
    property split_arch : String? = nil
    # release --merge: reuse the binaries of split builds.
    property? merge : Bool = false
    property? allow_missing : Bool = false
    # True for `release`: a token is then required unless publishing is
    # skipped or the run is a snapshot.
    property? publish : Bool = false

    def initialize
    end
  end

  # State shared by the pipes of one run. Filled progressively: the git pipe
  # sets the version facts, the build pipe registers binaries, and so on.
  class Context
    getter dir : String
    getter config : Config
    getter host : Host
    getter options : Options
    getter logger : Logger
    getter artifacts : ArtifactRegistry
    # The process environment the run started with; templates read it
    # through `.Env`, and builds and hooks inherit it.
    getter env : Hash(String, String)
    getter now : Time

    property version_info : VersionInfo = VersionInfo.snapshot(nil, "0000000")
    property previous_tag : String? = nil
    property commit : String = ""
    property short_commit : String = ""
    property branch : String = ""
    property commit_time : Time = Time.unix(0)
    # The release notes: the generated changelog or --release-notes.
    property changelog : String = ""
    @crystal_version : String? = nil

    # Builds the GitHub client from a token; specs swap in a fake transport.
    property github_client_factory : Proc(String, Github::Client) = ->(token : String) { Github::Client.new(token) }

    def initialize(@dir : String, @config : Config, @host : Host, @options : Options, @logger : Logger,
                   *, @env : Hash(String, String) = ENV.to_h, @now : Time = Time.utc)
      @artifacts = ArtifactRegistry.new
    end

    # GITHUB_TOKEN, else GH_TOKEN, else nil.
    def github_token : String?
      {"GITHUB_TOKEN", "GH_TOKEN"}.each { |name| @env[name]?.presence.try { |token| return token } }
      nil
    end

    def github_client(token : String? = nil) : Github::Client
      value = token.presence || github_token || raise ConfigError.new("GITHUB_TOKEN or GH_TOKEN is required to publish")
      client = @github_client_factory.call(value)
      client.on_wait = ->(message : String) { @logger.warn(message) }
      client
    end

    # The client that pushes to a tap or a registry. An empty `token` means
    # GITHUB_TOKEN; a token template that renders empty (a CI secret that is
    # not set) is an error, never a silent fallback on GITHUB_TOKEN, which
    # cannot write to another repository.
    def repository_client(repository : Config::Repository, field : String) : Github::Client
      return github_client if repository.token.strip.empty?
      token = render(repository.token, "#{field}.token")
      raise ConfigError.new("#{field}.token: the token is empty") if token.strip.empty?
      github_client(token)
    end

    # The private key packages are signed with, rendered from its template.
    # A release whose key is not set, or renders empty (a CI secret that is
    # missing), is an error: going out unsigned would only show on the
    # machines that refuse the package. A snapshot, which publishes nothing
    # and runs where the release key is not (a pull request, a developer's
    # machine), gets nil instead.
    def signing_key(template : String, field : String, snapshot : Bool = snapshot?) : String?
      key =
        begin
          render(template, field)
        rescue error : TemplateError
          # The validation has parsed the template: what fails here is an
          # environment variable that is not set.
          raise error unless snapshot
          ""
        end
      return key unless key.strip.empty?
      raise ConfigError.new("#{field}: the key is empty") unless snapshot
      nil
    end

    # owner/name of the release: release.github, else the origin remote.
    def release_repo : {String, String}
      if github = @config.release.github
        return {github.owner, github.name}
      end
      Git.new(@dir).github_remote || raise ConfigError.new("release.github is not set and the origin remote is not a GitHub repository")
    end

    # The URL an uploaded asset is downloaded from.
    def download_url(name : String) : String
      owner, repo = release_repo
      "https://github.com/#{owner}/#{repo}/releases/download/#{URI.encode_path_segment(@version_info.tag)}/#{URI.encode_path_segment(name)}"
    end

    # `crystal env CRYSTAL_VERSION` of the host, read once, on first use.
    def crystal_version : String
      @crystal_version ||= begin
        output = IO::Memory.new
        status = Process.run("crystal", ["env", "CRYSTAL_VERSION"], output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s.strip : ""
      rescue File::NotFoundError
        ""
      end
    end

    def crystal_version=(@crystal_version : String?)
    end

    def snapshot? : Bool
      @version_info.snapshot?
    end

    # The global template variables.
    def vars : Hash(String, String)
      info = @version_info
      {
        "ProjectName"    => @config.project_name,
        "Version"        => info.version,
        "RawVersion"     => info.raw_version,
        "Tag"            => info.tag,
        "PreviousTag"    => @previous_tag || "",
        "Major"          => info.major,
        "Minor"          => info.minor,
        "Patch"          => info.patch,
        "Prerelease"     => info.prerelease,
        "Commit"         => @commit,
        "ShortCommit"    => @short_commit,
        "Branch"         => @branch,
        "Date"           => @now.to_utc.to_rfc3339,
        "Timestamp"      => @now.to_unix.to_s,
        "CrystalVersion" => crystal_version,
        "IsSnapshot"     => info.snapshot?.to_s,
      }
    end

    # The global variables plus those of one build on one platform.
    def platform_vars(build : Config::Build, platform : Config::Platform) : Hash(String, String)
      vars.merge({
        "Os"     => platform.os,
        "Arch"   => platform.arch,
        "Target" => Builders.triple(platform.os, platform.arch, platform.static?),
        "Binary" => build.binary,
      })
    end

    def render(source : String, field : String, vars : Hash(String, String) = self.vars) : String
      Template.render(source, field, vars, @env)
    end

    # The environment of a build process: the run's environment, then the
    # global `env:`, then the build's `env:`, each rendered for the platform.
    # This is how versions reach the code: Crystal reads them at compile time
    # with `{{ env("X") }}`.
    def build_env(build : Config::Build, platform : Config::Platform) : Hash(String, String)
      @env.merge(config_env(build, platform))
    end

    # Only what the config sets for a build: the global `env:`, then the
    # build's `env:`, rendered. This is what a docker build receives with -e,
    # since the host environment has no business inside the container.
    def config_env(build : Config::Build, platform : Config::Platform) : Hash(String, String)
      vars = platform_vars(build, platform)
      env = rendered_global_env
      index = @config.builds.index(build) || 0
      build.env.each_with_index do |entry, position|
        name, _, value = entry.partition('=')
        env[name] = render(value, "builds[#{index}].env[#{position}]", vars)
      end
      env
    end

    # The run's environment plus the rendered global `env:`.
    def global_env : Hash(String, String)
      @env.merge(rendered_global_env)
    end

    private def rendered_global_env : Hash(String, String)
      env = {} of String => String
      @config.env.each_with_index do |entry, position|
        name, _, value = entry.partition('=')
        env[name] = render(value, "env[#{position}]")
      end
      env
    end

    # The dist directory, absolute.
    def dist_path : String
      File.expand_path(@config.dist, @dir)
    end

    # A path under the dist directory. (A typed splat needs at least one
    # argument, hence the bare overload above.)
    def dist_path(*parts : String) : String
      File.join(dist_path, *parts)
    end

    # `name`, checked to be a plain file name: what a name template renders
    # is written directly under dist/, so a `/` in it (a branch name, a
    # `../`) would write somewhere else, or nowhere.
    def file_name(name : String, field : String) : String
      if name.empty? || name.includes?('/') || name.in?(".", "..")
        raise PackageError.new("#{field}: #{name.inspect} is not a plain file name")
      end
      name
    end

    # `path` relative to the project directory, as stored in artifacts.
    def relative(path : String) : String
      Path[path].relative_to(@dir).to_s
    end
  end
end
