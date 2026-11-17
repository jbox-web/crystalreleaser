require "./config"
require "./host"
require "./template"

module Crystalreleaser
  # Static checks on a loaded config: everything that can be known without
  # building anything. Errors are collected rather than raised one by one, so
  # a user fixes a broken file in one round. Used by `crystalreleaser check`
  # and by the `validate` pipe.
  class Validator
    record Result, errors : Array(String), warnings : Array(String)

    PLATFORMS  = %w[linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 freebsd/amd64]
    STRATEGIES = %w[docker cross native]
    SYSTEMS    = %w[linux darwin freebsd windows]
    LINKERS    = %w[zig cc]
    # `binary` is the binary itself, with no archive around it.
    ARCHIVE_FORMATS = %w[tar.gz zip binary]

    # Template variables each kind of field can provide.
    GLOBAL_VARS = %w[
      ProjectName Version RawVersion Tag PreviousTag Major Minor Patch
      Prerelease Commit ShortCommit Branch Date Timestamp CrystalVersion
      IsSnapshot
    ]
    PLATFORM_VARS = GLOBAL_VARS + %w[Os Arch Target Binary]
    PACKAGE_VARS  = PLATFORM_VARS + %w[PackageName]

    # What Homebrew accepts as a formula name: it becomes a file name, a path
    # in the tap and, through `Homebrew.class_name`, a Ruby class.
    FORMULA_NAME = /\A[A-Za-z0-9][A-Za-z0-9+_.@-]*\z/
    # The union of what dpkg and rpm accept; written as is in both formats.
    PACKAGE_NAME = /\A[A-Za-z0-9][A-Za-z0-9+_.-]*\z/
    # An owner or a repository name, interpolated in API paths and URLs.
    GITHUB_NAME = /\A[A-Za-z0-9_.-]+\z/
    ENV_NAME    = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    def initialize(@config : Config, @host : Host)
      @errors = [] of String
      @warnings = [] of String
    end

    def run : Result
      @errors.clear
      @warnings.clear
      check_version
      check_plain_name(@config.project_name, "project_name")
      check_dist
      check_env
      check_hooks
      check_builds
      check_archives
      check_checksum
      check_changelog
      check_release
      check_nfpms
      check_brews
      check_aqua
      Result.new(@errors.dup, @warnings.dup)
    end

    # Like `#run`, but raises a ConfigError listing every error. Returns the
    # warnings.
    def run! : Array(String)
      result = run
      unless result.errors.empty?
        raise ConfigError.new("invalid configuration:\n" + result.errors.join('\n') { |error| "  - #{error}" })
      end
      result.warnings
    end

    private def check_version : Nil
      version = @config.version
      @errors << "version: unsupported config version #{version} (expected 1)" unless version == 1
    end

    private def check_dist : Nil
      @config.dist_error.try { |error| @errors << error }
    end

    private def check_env : Nil
      check_env_list(@config.env, "env", GLOBAL_VARS)
    end

    private def check_env_list(entries : Array(String), field : String, vars : Array(String)) : Nil
      entries.each_with_index do |entry, index|
        name, separator, value = entry.partition('=')
        if separator.empty? || name.empty?
          @errors << "#{field}[#{index}]: expected KEY=VALUE, got '#{entry}'"
        elsif !ENV_NAME.matches?(name)
          @errors << "#{field}[#{index}]: #{name.inspect} is not an environment variable name"
        else
          check_template(value, "#{field}[#{index}]", vars)
        end
      end
    end

    private def check_hooks : Nil
      @config.before.hooks.each_with_index do |hook, index|
        check_template(hook, "before.hooks[#{index}]", GLOBAL_VARS)
      end
    end

    # A name that ends up in file names: the output folder of a build, the
    # binary, the default archive name.
    private def check_plain_name(name : String, field : String) : Nil
      return unless name.blank? || name != name.strip || name.includes?('/') || name.in?(".", "..")
      @errors << "#{field}: #{name.inspect} is not a plain name"
    end

    # A path inside something crystalreleaser writes (an archive, a tap): it
    # must stay inside, so neither absolute nor going up.
    private def check_relative_path(path : String, field : String) : Nil
      return if !path.starts_with?('/') && !path.empty? && Path.posix(path).normalize.to_s == path && !path.split('/').includes?("..")
      @errors << "#{field}: must be a relative path without '..' or '//', got #{path.inspect}"
    end

    private def check_github_name(name : String, field : String) : Nil
      return if GITHUB_NAME.matches?(name) && !name.in?(".", "..")
      @errors << "#{field}: #{name.inspect} is not a GitHub owner or repository name"
    end

    private def check_repository(repository : Config::Repository, field : String) : Nil
      check_github_name(repository.owner, "#{field}.owner")
      check_github_name(repository.name, "#{field}.name")
      check_template(repository.token, "#{field}.token", GLOBAL_VARS)
    end

    private def check_builds : Nil
      if @config.builds.empty?
        @errors << "builds: nothing to build: shard.yml declares no target and no build is configured"
      end
      check_unique(@config.builds.map(&.id), "builds", "id")
      @config.builds.each_with_index do |build, index|
        field = "builds[#{index}]"
        check_plain_name(build.id, "#{field}.id")
        check_plain_name(build.binary, "#{field}.binary")
        unless LINKERS.includes?(build.cross.linker)
          @errors << "#{field}.cross.linker: unknown linker '#{build.cross.linker}' (expected zig or cc)"
        end
        check_build_source(build, field)
        build.static_libs.try { |static| check_static_libs(build, static, field) }
        check_platforms(build, field)
        check_env_list(build.env, "#{field}.env", PLATFORM_VARS)
        check_docker(build.docker, field, build.platforms.any? { |platform| platform.strategy == "docker" })
        build.cross.sysroot.try { |sysroot| check_template(sysroot, "#{field}.cross.sysroot", PLATFORM_VARS) }
      end
    end

    private def check_docker(docker : Config::Docker, field : String, used : Bool) : Nil
      if dockerfile = docker.dockerfile
        @errors << "#{field}.docker: set image or dockerfile, not both" if docker.image
        check_relative_path(dockerfile, "#{field}.docker.dockerfile")
      elsif docker.target
        @errors << "#{field}.docker.target: only used with docker.dockerfile"
      end
      check_generated_image(docker, field)
      if image = docker.image
        check_template(image, "#{field}.docker.image", PLATFORM_VARS)
        @errors << "#{field}.docker.image: must not be empty" if used && image.blank?
      end
    end

    # The settings of the image crystalreleaser generates, which only exists
    # without an image or a Dockerfile.
    private def check_generated_image(docker : Config::Docker, field : String) : Nil
      if (docker.alpine || !docker.packages.empty?) && (docker.dockerfile || docker.image)
        @errors << "#{field}.docker: alpine and packages only apply to the generated image, " \
                   "not with #{docker.dockerfile ? "dockerfile" : "image"}"
      end
      docker.alpine.try do |alpine|
        @errors << "#{field}.docker.alpine: #{alpine.inspect} is not an Alpine release (e.g. 3.24)" unless alpine.matches?(/\A\d+\.\d+\z/)
      end
      docker.packages.each_with_index do |package, index|
        unless package.matches?(/\A[a-z0-9][a-z0-9+._-]*(?:[~=<>]+[A-Za-z0-9.+_-]+)?\z/)
          @errors << "#{field}.docker.packages[#{index}]: #{package.inspect} is not an apk package name"
        end
      end
    end

    private def check_static_libs(build : Config::Build, static : Config::StaticLibs, field : String) : Nil
      unless static.formula.matches?(/\A[a-z0-9][a-z0-9@+._\/-]*\z/)
        @errors << "#{field}.static_libs.formula: #{static.formula.inspect} is not a Homebrew formula name"
      end
      @errors << "#{field}.static_libs.libs: at least one library is required" if static.libs.empty?
      static.libs.each_with_index do |name, index|
        if name.starts_with?("lib") || name.ends_with?(".a") || name.ends_with?(".dylib")
          @errors << "#{field}.static_libs.libs[#{index}]: #{name.inspect} is a file name: write the library name, " \
                     "as for -l (ssl for libssl.a)"
        elsif !name.matches?(/\A[A-Za-z0-9_+.-]+\z/)
          @errors << "#{field}.static_libs.libs[#{index}]: #{name.inspect} is not a library name"
        end
      end
      # Ignored elsewhere: the linux builds are static already, and a cross
      # build links against its sysroot.
      unless build.platforms.any? { |platform| platform.os == "darwin" && platform.strategy == "native" }
        @warnings << "#{field}.static_libs: only native darwin builds use it, and this build has none"
      end
    end

    private def check_build_source(build : Config::Build, field : String) : Nil
      target = build.target
      if target && !@config.shard_targets.has_key?(target)
        @errors << "#{field}.target: no target '#{target}' in shard.yml"
      elsif target.nil? && build.main.nil?
        @errors << "#{field}: set either target or main"
      end
    end

    private def check_platforms(build : Config::Build, field : String) : Nil
      seen = Set(String).new
      needs_sysroot = false
      build.platforms.each_with_index do |platform, index|
        where = "#{field}.platforms[#{index}]"
        couple = "#{platform.os}/#{platform.arch}"
        unless seen.add?(couple)
          @errors << "#{where}: duplicate platform #{couple}"
          next
        end
        unless STRATEGIES.includes?(platform.strategy)
          @errors << "#{where}.strategy: unknown strategy '#{platform.strategy}' (expected docker, cross or native)"
          next
        end
        needs_sysroot ||= platform.strategy == "cross"
        check_platform(platform, where, couple)
        # The base of an image built from a Dockerfile is not known before.
        if platform.strategy == "docker" && !platform.static? && build.docker.dockerfile.nil? &&
           (build.docker.image.nil? || build.docker.image.to_s.includes?("alpine"))
          @warnings << "#{where}: a docker build in an Alpine image without static: true is linked dynamically " \
                       "against musl, and only runs on a musl system"
        end
      end
      if needs_sysroot && build.cross.sysroot.nil?
        @errors << "#{field}.cross.sysroot: required by the cross strategy"
      end
    end

    private def check_platform(platform : Config::Platform, where : String, couple : String) : Nil
      if platform.os == "windows"
        @warnings << "#{where}: #{couple} is accepted but cannot be built yet; it will be skipped"
      elsif !PLATFORMS.includes?(couple)
        @errors << "#{where}: unsupported platform #{couple} (supported: #{PLATFORMS.join(", ")})"
      elsif platform.strategy == "docker" && platform.os != "linux"
        @errors << "#{where}: the docker strategy only builds linux binaries"
      elsif platform.static? && platform.os == "darwin"
        @errors << "#{where}: static linking is not supported on darwin"
      elsif platform.strategy == "native"
        check_native(platform, where, couple)
      end
    end

    private def check_native(platform : Config::Platform, where : String, couple : String) : Nil
      if !@host.matches?(platform.os, platform.arch)
        @warnings << "#{where}: native build of #{couple} on a #{@host} host will be skipped"
      elsif platform.static? && !(@host.os == "linux" && @host.musl?)
        @errors << "#{where}: a static native build needs a musl host (e.g. Alpine); use strategy: docker"
      end
    end

    private def check_archives : Nil
      check_unique(@config.archives.map(&.id), "archives", "id")
      @config.archives.each_with_index do |archive, index|
        field = "archives[#{index}]"
        check_build_refs(archive.builds, "#{field}.builds")
        check_formats(archive.formats, "#{field}.formats", ARCHIVE_FORMATS, "tar.gz, zip or binary")
        archive.format_overrides.each_with_index do |override, position|
          where = "#{field}.format_overrides[#{position}]"
          unless SYSTEMS.includes?(override.os)
            @errors << "#{where}.os: unknown os '#{override.os}' (expected linux, darwin, freebsd or windows)"
          end
          check_formats(override.formats, "#{where}.formats", ARCHIVE_FORMATS, "tar.gz, zip or binary")
        end
        check_template(archive.name_template, "#{field}.name_template", PLATFORM_VARS)
        archive.file_specs.each_with_index do |spec, position|
          spec.dst.try { |dst| check_relative_path(dst, "#{field}.files[#{position}].dst") }
        end
      end
    end

    private def check_checksum : Nil
      checksum = @config.checksum
      unless checksum.algorithm == "sha256"
        @errors << "checksum.algorithm: unsupported algorithm '#{checksum.algorithm}' (expected sha256)"
      end
      check_template(checksum.name_template, "checksum.name_template", GLOBAL_VARS)
    end

    private def check_changelog : Nil
      changelog = @config.changelog
      case changelog.use
      when "git"    then nil
      when "github" then @errors << "changelog.use: 'github' is not supported yet (expected git)"
      else               @errors << "changelog.use: unknown source '#{changelog.use}' (expected git)"
      end
      unless changelog.sort.in?("asc", "desc")
        @errors << "changelog.sort: unknown order '#{changelog.sort}' (expected asc or desc)"
      end
      changelog.filters.exclude.each_with_index do |pattern, index|
        check_regex(pattern, "changelog.filters.exclude[#{index}]")
      end
      last = changelog.groups.size - 1
      changelog.groups.each_with_index do |group, index|
        if regexp = group.regexp
          check_regex(regexp, "changelog.groups[#{index}].regexp")
        elsif index != last
          @errors << "changelog.groups[#{index}]: only the last group may omit regexp"
        end
      end
    end

    private def check_release : Nil
      release = @config.release
      unless release.prerelease.in?("auto", "true", "false")
        @errors << "release.prerelease: unknown value '#{release.prerelease}' (expected auto, true or false)"
      end
      unless release.make_latest.in?("true", "false", "legacy")
        @errors << "release.make_latest: unknown value '#{release.make_latest}' (expected true, false or legacy)"
      end
      if github = release.github
        if github.owner.strip.empty? || github.name.strip.empty?
          @errors << "release.github: owner and name must not be empty"
        else
          check_github_name(github.owner, "release.github.owner")
          check_github_name(github.name, "release.github.name")
        end
      end
      check_template(release.name_template, "release.name_template", GLOBAL_VARS)
      check_template(release.header, "release.header", GLOBAL_VARS)
      check_template(release.footer, "release.footer", GLOBAL_VARS)
    end

    private def check_nfpms : Nil
      check_unique(@config.nfpms.map(&.id), "nfpms", "id")
      @config.nfpms.each_with_index do |nfpm, index|
        field = "nfpms[#{index}]"
        check_build_refs(nfpm.builds, "#{field}.builds")
        check_formats(nfpm.formats, "#{field}.formats", %w[deb rpm], "deb or rpm")
        @errors << "#{field}.maintainer: required by the deb and rpm formats" if nfpm.maintainer.strip.empty?
        unless PACKAGE_NAME.matches?(nfpm.package_name)
          @errors << "#{field}.package_name: #{nfpm.package_name.inspect} is not a package name (letters, digits and + - _ .)"
        end
        check_template(nfpm.file_name_template, "#{field}.file_name_template", PACKAGE_VARS)
        check_install_path(nfpm.bindir, "#{field}.bindir")
        nfpm.contents.each_with_index do |content, position|
          check_install_path(content.dst, "#{field}.contents[#{position}].dst")
          unless content.type.in?("", "config", "config|noreplace")
            @errors << "#{field}.contents[#{position}].type: unknown type '#{content.type}' (expected config or config|noreplace)"
          end
        end
      end
    end

    # Where a package installs a file: written as is in the package, so it
    # must already be the absolute, normalized path.
    private def check_install_path(path : String, field : String) : Nil
      return if path.starts_with?('/') && path.size > 1 && Path.posix(path).normalize.to_s == path
      @errors << "#{field}: must be an absolute path without '..' or '//', got #{path.inspect}"
    end

    private def check_brews : Nil
      check_unique(@config.brews.map(&.name), "brews", "name")
      @config.brews.each_with_index do |brew, index|
        unless FORMULA_NAME.matches?(brew.name)
          @errors << "brews[#{index}].name: #{brew.name.inspect} is not a formula name (letters, digits and + - _ . @)"
        end
        check_relative_path(brew.directory, "brews[#{index}].directory")
        brew.repository.try { |repository| check_repository(repository, "brews[#{index}].repository") }
        check_skip_upload(brew.skip_upload, "brews[#{index}].skip_upload")
      end
    end

    private def check_aqua : Nil
      seen = Set({String, String, String}).new
      @config.aqua.each do |aqua|
        repository = aqua.repository
        next if seen.add?({repository.owner, repository.name, aqua.path})
        @errors << "aqua: duplicate path '#{aqua.path}' in #{repository.owner}/#{repository.name}"
      end
      @config.aqua.each_with_index do |aqua, index|
        check_relative_path(aqua.path, "aqua[#{index}].path")
        check_repository(aqua.repository, "aqua[#{index}].repository")
        check_skip_upload(aqua.skip_upload, "aqua[#{index}].skip_upload")
      end
    end

    private def check_skip_upload(value : String, field : String) : Nil
      return if value.in?("auto", "true", "false")
      @errors << "#{field}: unknown value '#{value}' (expected auto, true or false)"
    end

    private def check_unique(values : Array(String), section : String, key : String) : Nil
      seen = Set(String).new
      values.each do |value|
        @errors << "#{section}: duplicate #{key} '#{value}'" unless seen.add?(value)
      end
    end

    private def check_build_refs(references : Array(String), field : String) : Nil
      ids = @config.builds.map(&.id)
      references.each do |reference|
        @errors << "#{field}: unknown build '#{reference}'" unless ids.includes?(reference)
      end
    end

    private def check_formats(formats : Array(String), field : String, allowed : Array(String), expected : String) : Nil
      @errors << "#{field}: at least one format is required" if formats.empty?
      formats.each do |format|
        @errors << "#{field}: unknown format '#{format}' (expected #{expected})" unless allowed.includes?(format)
      end
    end

    private def check_regex(pattern : String, field : String) : Nil
      Regex.new(pattern)
    rescue error : ArgumentError
      @errors << "#{field}: invalid regular expression: #{error.message}"
    end

    private def check_template(source : String, field : String, vars : Array(String)) : Nil
      Template.parse(source, field).check_available(vars)
    rescue error : TemplateError
      @errors << error.message.to_s
    end
  end
end
