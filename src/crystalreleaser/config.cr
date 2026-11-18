require "yaml"

require "./error"
require "./host"
require "./shard_manifest"

module Crystalreleaser
  # `.crystalreleaser.yml`, modelled on `.goreleaser.yaml`. Every key is
  # optional; what is left out is derived from shard.yml by `#apply_defaults`
  # (project name, one native build per target). Unknown keys are errors:
  # a typo silently ignored is a release silently wrong.
  class Config
    include YAML::Serializable
    include YAML::Serializable::Strict

    # Looked up in this order when no file is given explicitly.
    FILE_NAMES = %w[.crystalreleaser.yml .crystalreleaser.yaml crystalreleaser.yml]

    DEFAULT_ARCHIVE_NAME = "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"
    DEFAULT_PACKAGE_NAME = "{{ .PackageName }}_{{ .Version }}_{{ .Arch }}"

    class Before
      include YAML::Serializable
      include YAML::Serializable::Strict

      property hooks : Array(String) = [] of String

      def initialize
      end
    end

    class Platform
      include YAML::Serializable
      include YAML::Serializable::Strict

      property os : String
      property arch : String
      # docker | cross | native
      property strategy : String = "native"
      property? static : Bool = false

      def initialize(@os : String, @arch : String, @strategy : String = "native", @static : Bool = false)
      end
    end

    class Docker
      include YAML::Serializable
      include YAML::Serializable::Strict

      # The stable Alpine whose own Crystal package the generated image
      # installs.
      DEFAULT_ALPINE = "3.24"

      # The build image, one of three: `image`, pulled as it is; the image
      # built from the project's own `dockerfile` (its `target` stage, if
      # given); by default, the image built from a Dockerfile crystalreleaser
      # writes: `alpine`, its Crystal and the static libraries the stdlib
      # links, plus the project's `packages`.
      property image : String? = nil
      property dockerfile : String? = nil
      property target : String? = nil
      property alpine : String? = nil
      property packages : Array(String) = [] of String
      property? platform_flag : Bool = true
      property? shards_install : Bool = true

      def initialize
      end
    end

    class Cross
      include YAML::Serializable
      include YAML::Serializable::Strict

      # zig | cc
      property linker : String = "zig"
      property sysroot : String? = nil
      property link_flags : Array(String) = [] of String

      def initialize
      end
    end

    # Libraries of a Homebrew formula a native darwin build links
    # statically: `libs` are their names as for -l (ssl for libssl.a). One
    # entry of a build's `static_libs` list.
    class StaticLibs
      include YAML::Serializable
      include YAML::Serializable::Strict

      property formula : String
      property libs : Array(String)

      def initialize(@formula : String, @libs : Array(String))
      end
    end

    class Build
      include YAML::Serializable
      include YAML::Serializable::Strict

      # Default: the target, else the project name.
      property id : String = ""
      # Target name in shard.yml; `main` is deduced from it.
      property target : String? = nil
      property main : String? = nil
      # Default: the target, else the id.
      property binary : String = ""
      # Other names the binary is installed under, written as symbolic links
      # to it next to it. Only tar.gz archives can hold them.
      property aliases : Array(String) = [] of String
      property flags : Array(String) = ["--release"]
      property env : Array(String) = [] of String
      # Default: the host, built natively.
      property platforms : Array(Platform) = [] of Platform
      property docker : Docker = Docker.new
      property cross : Cross = Cross.new
      # One entry per Homebrew formula. On the build, not on a platform: arm64
      # and amd64 must embed the same libraries, which the same formulas for
      # both is what guarantees.
      property static_libs : Array(StaticLibs) = [] of StaticLibs

      def initialize(@id : String = "", @target : String? = nil)
      end

      # A second name of a binary: a file name in the folder it is installed
      # in, written as a symbolic link next to it.
      ALIAS_NAME = /\A[A-Za-z0-9._-]+\z/

      # `.` and `..` match the pattern and name no file.
      def self.alias_name?(name : String) : Bool
        ALIAS_NAME.matches?(name) && !name.in?(".", "..")
      end
    end

    # One `files:` entry in its long form. The short form is a bare glob.
    class FileSpec
      include YAML::Serializable
      include YAML::Serializable::Strict

      property src : String
      property dst : String? = nil

      def initialize(@src : String, @dst : String? = nil)
      end
    end

    class FormatOverride
      include YAML::Serializable
      include YAML::Serializable::Strict

      property os : String
      property formats : Array(String)
    end

    class Archive
      include YAML::Serializable
      include YAML::Serializable::Strict

      property id : String = "default"
      # Default: every build.
      property builds : Array(String) = [] of String
      # tar.gz | zip
      property formats : Array(String) = ["tar.gz"]
      property format_overrides : Array(FormatOverride) = [] of FormatOverride
      property name_template : String = DEFAULT_ARCHIVE_NAME
      property? wrap_in_directory : Bool = false
      # Globs, short (`LICENSE`) or long (`{src: completions/*, dst: completions}`).
      property files : Array(String | FileSpec) = ["LICENSE*", "README*", "CHANGELOG*"] of String | FileSpec

      def initialize
      end

      # `files` with the short form expanded.
      def file_specs : Array(FileSpec)
        files.map do |entry|
          entry.is_a?(String) ? FileSpec.new(entry) : entry
        end
      end
    end

    class Checksum
      include YAML::Serializable
      include YAML::Serializable::Strict

      property name_template : String = "checksums.txt"
      property algorithm : String = "sha256"
      # One `<asset>.sha256` per asset instead of the one file `name_template`
      # names: what suits a project whose users fetch a single asset.
      property? split : Bool = false

      def initialize
      end
    end

    class ChangelogFilters
      include YAML::Serializable
      include YAML::Serializable::Strict

      property exclude : Array(String) = [] of String

      def initialize
      end
    end

    class ChangelogGroup
      include YAML::Serializable
      include YAML::Serializable::Strict

      property title : String
      # Absent on the last group, which catches every other commit.
      property regexp : String? = nil
    end

    class Changelog
      include YAML::Serializable
      include YAML::Serializable::Strict

      # git | github (not supported yet)
      property use : String = "git"
      # asc | desc
      property sort : String = "asc"
      property filters : ChangelogFilters = ChangelogFilters.new
      property groups : Array(ChangelogGroup) = [] of ChangelogGroup

      def initialize
      end
    end

    class GithubRepo
      include YAML::Serializable
      include YAML::Serializable::Strict

      property owner : String
      property name : String
    end

    class Release
      include YAML::Serializable
      include YAML::Serializable::Strict

      property github : GithubRepo? = nil
      property? draft : Bool = false
      # auto (semver pre-release => prerelease) | true | false
      property prerelease : String = "auto"
      property? replace_existing_artifacts : Bool = false
      # true | false | legacy: whether publishing marks the release "Latest".
      # true (what GitHub does when told nothing) marks it whatever its
      # version; legacy lets GitHub pick by version, so that a v1.9.1
      # published after v2.0.0 does not take the label.
      property make_latest : String = "true"
      property name_template : String = "{{ .Tag }}"
      property header : String = ""
      property footer : String = ""

      def initialize
      end
    end

    class Content
      include YAML::Serializable
      include YAML::Serializable::Strict

      property src : String
      property dst : String
      # "" (an ordinary file) | config | config|noreplace, as in nfpm: a
      # configuration file is not silently overwritten on upgrade.
      property type : String = ""
    end

    # The private key the .rpm packages are signed with, and its passphrase
    # when it has one. Both are templates, and secrets: usually
    # `{{ .Env.RPM_SIGNING_KEY }}`, never the value itself. The key is the
    # text `gpg --armor --export-secret-keys <key id>` prints, for one key.
    class RpmSignature
      include YAML::Serializable
      include YAML::Serializable::Strict

      property key : String
      property passphrase : String = ""
    end

    # What only the rpm format of an `nfpms` entry takes.
    class RpmOptions
      include YAML::Serializable
      include YAML::Serializable::Strict

      # Default: the packages are not signed.
      property signature : RpmSignature? = nil

      def initialize
      end
    end

    class Nfpm
      include YAML::Serializable
      include YAML::Serializable::Strict

      property id : String = "default"
      # Default: every build.
      property builds : Array(String) = [] of String
      # Default: the project name.
      property package_name : String = ""
      # deb | rpm
      property formats : Array(String) = ["deb", "rpm"]
      property vendor : String = ""
      property homepage : String = ""
      property maintainer : String = ""
      property description : String = ""
      property license : String = ""
      property section : String = "utils"
      property priority : String = "optional"
      property bindir : String = "/usr/bin"
      property contents : Array(Content) = [] of Content
      property dependencies : Array(String) = [] of String
      property file_name_template : String = DEFAULT_PACKAGE_NAME
      property rpm : RpmOptions = RpmOptions.new
    end

    # A repository crystalreleaser pushes a generated file to.
    class Repository
      include YAML::Serializable
      include YAML::Serializable::Strict

      property owner : String
      property name : String
      property branch : String = "main"
      # Usually `{{ .Env.SOME_TOKEN }}`; empty means GITHUB_TOKEN.
      property token : String = ""
    end

    class Brew
      include YAML::Serializable
      include YAML::Serializable::Strict

      # Default: the project name.
      property name : String = ""
      property repository : Repository? = nil
      property directory : String = "Formula"
      property homepage : String = ""
      property description : String = ""
      property license : String = ""
      property install : String = ""
      property test : String = ""
      # false | true | auto (not pushed for a semver pre-release)
      property skip_upload : String = "false"
    end

    class Aqua
      include YAML::Serializable
      include YAML::Serializable::Strict

      property repository : Repository
      property path : String
      property description : String = ""
      # false | true | auto (not pushed for a semver pre-release)
      property skip_upload : String = "false"
    end

    property version : Int32 = 1
    # Default: shard.yml name.
    property project_name : String = ""
    property dist : String = "dist"
    property env : Array(String) = [] of String
    property before : Before = Before.new
    property builds : Array(Build) = [] of Build
    property archives : Array(Archive) = [] of Archive
    property checksum : Checksum = Checksum.new
    property changelog : Changelog = Changelog.new
    property release : Release = Release.new
    property nfpms : Array(Nfpm) = [] of Nfpm
    property brews : Array(Brew) = [] of Brew
    property aqua : Array(Aqua) = [] of Aqua

    # The file the config was read from, relative to the project when found
    # by lookup; nil when every value comes from the defaults.
    @[YAML::Field(ignore: true)]
    property file : String? = nil

    # shard.yml targets (name => main), for the validator.
    @[YAML::Field(ignore: true)]
    property shard_targets : Hash(String, String) = {} of String => String

    # shard.yml `version` and `crystal` constraint.
    @[YAML::Field(ignore: true)]
    property shard_version : String = ""
    @[YAML::Field(ignore: true)]
    property shard_crystal : String = ""

    def initialize
    end

    # Reads the config of the project in `dir` (`path` when given, else the
    # first of FILE_NAMES found, else nothing) and fills in the defaults.
    def self.load(dir : String, path : String?, host : Host) : Config
      file = path || FILE_NAMES.find { |name| File.file?(File.join(dir, name)) }
      config =
        if file
          full = File.expand_path(file, dir)
          raise ConfigError.new("config file not found: #{file}") unless File.file?(full)
          parse(read(full, file), file)
        else
          Config.new
        end
      config.file = file
      config.apply_defaults(ShardManifest.load(dir), host)
      config
    end

    private def self.read(full : String, file : String) : String
      File.read(full)
    rescue error : File::Error
      raise ConfigError.new("cannot read #{file}: #{error.message}")
    end

    def self.parse(content : String, file : String) : Config
      return Config.new if content.strip.empty?
      documents = YAML::Nodes.parse_all(content)
      raise ConfigError.new("#{file}: only one YAML document is allowed") if documents.size > 1
      documents.each { |document| check_duplicate_keys(document, file) }
      documents.each { |document| check_static_libs_shape(document, file) }
      from_yaml(content)
    rescue error : YAML::ParseException
      error = inner_error(error, content) || error
      raise ConfigError.new("#{file}:#{error.line_number}:#{error.column_number}: #{describe(error)}")
    end

    # Up to 0.2.1 `static_libs` was the mapping of a single formula. YAML only
    # says "Expected sequence, not mapping" about it: say what to write.
    private def self.check_static_libs_shape(document : YAML::Nodes::Document, file : String) : Nil
      root = document.nodes.first?
      return unless root.is_a?(YAML::Nodes::Mapping)
      builds = mapping_value(root, "builds").try(&.[1])
      return unless builds.is_a?(YAML::Nodes::Sequence)
      builds.nodes.each do |build|
        next unless build.is_a?(YAML::Nodes::Mapping)
        key, value = mapping_value(build, "static_libs") || next
        next unless value.is_a?(YAML::Nodes::Mapping)
        formula = mapping_value(value, "formula").try(&.[1]).as?(YAML::Nodes::Scalar).try(&.value) || "<formula>"
        raise ConfigError.new("#{file}:#{key.start_line}:#{key.start_column}: static_libs is a list, one entry per " \
                              "Homebrew formula: write `- formula: #{formula}` with its `libs:` under it")
      end
    end

    # The key node and the value node of a key of a mapping.
    private def self.mapping_value(mapping : YAML::Nodes::Mapping, name : String) : {YAML::Nodes::Node, YAML::Nodes::Node}?
      mapping.nodes.each_slice(2) do |(key, value)|
        return {key, value} if key.is_a?(YAML::Nodes::Scalar) && key.value == name
      end
      nil
    end

    # The strict mode refuses unknown keys but not a key written twice: the
    # parser keeps the last one, and a whole section vanishes without a word.
    private def self.check_duplicate_keys(node : YAML::Nodes::Node, file : String) : Nil
      case node
      when YAML::Nodes::Document, YAML::Nodes::Sequence
        node.nodes.each { |child| check_duplicate_keys(child, file) }
      when YAML::Nodes::Mapping
        seen = Set(String).new
        node.nodes.each_slice(2) do |(key, value)|
          # `<<` is the merge key: it may be repeated.
          if key.is_a?(YAML::Nodes::Scalar) && key.value != "<<" && !seen.add?(key.value)
            raise ConfigError.new("#{file}:#{key.start_line}:#{key.start_column}: duplicate key '#{key.value}'")
          end
          check_duplicate_keys(value, file)
        end
      end
    end

    # The types an optional or two-form key can hold. When one of them fails
    # to parse, YAML::Serializable only reports "Couldn't parse (A | Nil)":
    # the node is parsed again as that type alone, to get the real error.
    INNER_TYPES = {
      "Crystalreleaser::Config::GithubRepo" => GithubRepo,
      "Crystalreleaser::Config::Repository" => Repository,
      "Crystalreleaser::Config::FileSpec"   => FileSpec,
    }

    private def self.inner_error(error : YAML::ParseException, content : String) : YAML::ParseException?
      match = error.message.to_s.match(/\ACouldn't parse \((.+?)\)/) || return
      type = match[1].split(" | ").compact_map { |name| INNER_TYPES[name]? }.first? || return
      node = find_node(YAML::Nodes.parse(content), error.line_number, error.column_number) || return
      type.new(YAML::ParseContext.new, node)
      nil
    rescue exception : YAML::ParseException
      exception
    end

    private def self.find_node(node : YAML::Nodes::Node, line : Int32, column : Int32) : YAML::Nodes::Node?
      return node if node.is_a?(YAML::Nodes::Mapping) && node.start_line == line && node.start_column == column
      children =
        case node
        when YAML::Nodes::Document, YAML::Nodes::Sequence, YAML::Nodes::Mapping then node.nodes
        else                                                                         [] of YAML::Nodes::Node
        end
      children.each { |child| find_node(child, line, column).try { |found| return found } }
      nil
    end

    # YAML::Serializable phrases its errors for Crystal developers; reword the
    # two a user meets most.
    private def self.describe(error : YAML::ParseException) : String
      message = error.message.to_s.gsub(/ at line \d+, column \d+/, "")
      if match = message.match(/\AUnknown ya?ml attribute: (.+)\z/i)
        "unknown key '#{match[1]}'"
      elsif match = message.match(/\AMissing ya?ml attribute: (.+)\z/i)
        "missing key '#{match[1]}'"
      else
        # "Expected mapping, not YAML::Nodes::Scalar": name the node in words.
        message.gsub(/YAML::Nodes::(\w+)/) { $1.downcase }
      end
    end

    # Why `dist` cannot be used, or nil when it is safe. --clean removes the
    # dist directory: it must therefore be a directory strictly inside the
    # project, never the project itself, a parent, or an absolute path.
    def dist_error : String?
      normalized = Path.posix(@dist).normalize.to_s
      safe = !@dist.strip.empty? && !@dist.starts_with?('/') && normalized != "." &&
             normalized != ".." && !normalized.starts_with?("../")
      return "dist: must be a directory inside the project, got #{@dist.inspect}" unless safe
      if normalized == ".git" || normalized.starts_with?(".git/")
        "dist: must not be the .git directory or inside it, got #{@dist.inspect}"
      end
    end

    def apply_defaults(shard : ShardManifest, host : Host) : Nil
      @project_name = shard.name if @project_name.empty?
      @shard_targets = shard.targets
      @shard_version = shard.version
      @shard_crystal = shard.crystal

      if @builds.empty?
        @builds = shard.targets.keys.map { |target| Build.new(target, target) }
      end
      @builds.each { |build| default_build(build, shard, host) }

      @archives = [Archive.new] if @archives.empty?
      all_builds = @builds.map(&.id)
      @archives.each { |archive| archive.builds = all_builds if archive.builds.empty? }
      @nfpms.each do |nfpm|
        nfpm.builds = all_builds if nfpm.builds.empty?
        nfpm.package_name = @project_name if nfpm.package_name.empty?
      end
      @brews.each { |brew| brew.name = @project_name if brew.name.empty? }
    end

    private def default_build(build : Build, shard : ShardManifest, host : Host) : Nil
      target = build.target
      build.id = target || @project_name if build.id.empty?
      build.binary = target || build.id if build.binary.empty?
      if build.main.nil? && target
        build.main = shard.targets[target]?
      end
      build.platforms = [Platform.new(host.os, host.arch)] if build.platforms.empty?
    end
  end
end
