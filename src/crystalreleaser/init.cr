require "./git"
require "./shard_manifest"

module Crystalreleaser
  # `crystalreleaser init`: a commented starting config for the project,
  # derived from shard.yml (one build per target) and from the origin remote
  # (the release repository).
  module Init
    # A YAML scalar: bare when it is a plain word YAML cannot take for
    # anything else, double-quoted otherwise (a name with a colon, a number,
    # `on`, `yes`...).
    def self.scalar(text : String) : String
      plain = text.matches?(/\A[A-Za-z_][A-Za-z0-9_.-]*\z/) &&
              !text.downcase.in?("y", "n", "yes", "no", "on", "off", "true", "false", "null")
      plain ? text : quoted(text)
    end

    # A YAML double-quoted scalar. Not `String#inspect`: Crystal escapes what
    # YAML does not know (`\#{`), and YAML then refuses the file.
    private def self.quoted(text : String) : String
      String.build do |io|
        io << '"'
        text.each_char do |char|
          case char
          when '"'  then io << "\\\""
          when '\\' then io << "\\\\"
          when '\n' then io << "\\n"
          when '\t' then io << "\\t"
          when '\r' then io << "\\r"
          else
            char.ord < 0x20 ? io << "\\x" << char.ord.to_s(16).rjust(2, '0') : io << char
          end
        end
        io << '"'
      end
    end

    def self.render(shard : ShardManifest, repo : {String, String}?) : String
      # Without a GitHub remote the repository is left commented out: a
      # placeholder owner would pass `check` and only fail a release once
      # everything is built.
      # In the commented examples a placeholder is harmless.
      owner = repo.try(&.[0]) || "OWNER"
      github =
        if repo
          "github:\n    owner: #{scalar(repo[0])}\n    name: #{scalar(repo[1])}"
        else
          "# github:\n  #   owner: OWNER\n  #   name: #{shard.name}"
        end
      String.build do |io|
        io << <<-YAML
          # crystalreleaser configuration for #{shard.name}.
          # Every key is optional: what is left out is derived from shard.yml.
          # Reference: https://github.com/jbox-web/crystalreleaser#configuration
          version: 1
          project_name: #{scalar(shard.name)}

          # Commands run before building; `shards install` belongs here when the
          # project has dependencies.
          # before:
          #   hooks:
          #     - shards install --production
          #     - crystal spec

          builds:

          YAML
        shard.targets.each_key do |target|
          variable = "#{target.upcase.gsub(/[^A-Z0-9]/, '_')}_VERSION"
          # An environment variable name cannot start with a digit.
          variable = "_#{variable}" if variable[0].ascii_number?
          io << <<-YAML
              - id: #{scalar(target)}
                target: #{scalar(target)}
                flags: [--release, --no-debug]
                # Read at compile time by the code:
                #   VERSION = {{ env("#{variable}") || "dev" }}
                env:
                  - #{variable}={{ .Version }}
                platforms:
                  # Static musl binaries, from any host with docker (arm64 via QEMU).
                  - os: linux
                    arch: amd64
                    strategy: docker
                    static: true
                  - os: linux
                    arch: arm64
                    strategy: docker
                    static: true
                  # Native builds only run on a matching host: macOS runners.
                  - os: darwin
                    arch: arm64
                    strategy: native
                  - os: darwin
                    arch: amd64
                    strategy: native

            YAML
        end
        io << <<-YAML
          archives:
            - id: default
              # tar.gz | zip | binary (the binary itself, with no archive)
              formats: [tar.gz]
              name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"
              files:
                - LICENSE*
                - README*

          checksum:
            name_template: checksums.txt

          changelog:
            sort: asc
            filters:
              exclude: ["^docs:", "^test:", "^chore:", "Merge pull request"]
            groups:
              - title: Features
                regexp: '^feat(\\(.+\\))?!?:'
              - title: Bug fixes
                regexp: '^fix(\\(.+\\))?!?:'
              - title: Others

          release:
            #{github}
            prerelease: auto

          # Linux packages, written natively.
          # nfpms:
          #   - id: packages
          #     formats: [deb, rpm]
          #     maintainer: Your Name <you@example.com>
          #     description: ...
          #     license: MIT

          # Homebrew formula, pushed to a tap.
          # brews:
          #   - name: #{shard.name}
          #     repository:
          #       owner: #{owner}
          #       name: homebrew-tap
          #       token: "{{ .Env.HOMEBREW_TAP_TOKEN }}"

          # aqua registry entry.
          # aqua:
          #   - repository:
          #       owner: #{owner}
          #       name: aqua-registry
          #       token: "{{ .Env.AQUA_REGISTRY_TOKEN }}"
          #     path: pkgs/#{owner}/#{shard.name}/registry.yaml

          YAML
      end
    end

    # Writes the config to `path` (relative to `dir`); never overwrites.
    def self.write(dir : String, path : String) : Nil
      full = File.expand_path(path, dir)
      raise UsageError.new("#{path} already exists") if File.exists?(full)
      shard = ShardManifest.load(dir)
      if shard.targets.empty?
        raise UsageError.new("shard.yml declares no target: there is nothing to build or release")
      end
      File.write(full, render(shard, Git.new(dir).github_remote))
    rescue error : File::Error
      raise ConfigError.new("cannot write #{path}: #{error.message}")
    end
  end
end
