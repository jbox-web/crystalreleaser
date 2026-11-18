require "yaml"

require "../artifact"
require "../context"
require "../pipe"
require "./homebrew"

module Crystalreleaser
  module Pipes
    # An aqua registry.yaml per `aqua:` entry. The `{{...}}` it contains are
    # aqua's own templates, so the file never goes through crystalreleaser's
    # template engine. It is written the way aqua registries write their
    # entries, list indented under `packages:`: a registry that concatenates
    # the entries of its packages (jbox-web's build-registry.sh) can take it
    # as it is, which libyaml's indentless lists broke. The asset template and
    # the supported environments are derived from the archives actually
    # produced. Written to dist/aqua/ before the release is published, with
    # no request: AquaPush pushes it to the registry afterwards.
    class Aqua < Pipe
      def name : String
        "aqua"
      end

      def description : String
        "generating the aqua registry entry"
      end

      def skip?(ctx : Context) : String?
        "no aqua configured" if ctx.config.aqua.empty?
      end

      def run(ctx : Context) : Nil
        ctx.config.aqua.each_with_index do |aqua, index|
          registry = registry(ctx, aqua)
          path = Aqua.local_path(ctx, index)
          Dir.mkdir_p(File.dirname(path))
          File.write(path, registry)
          ctx.artifacts.add(Artifact.new(Artifact::Type::AquaRegistry, File.basename(path), ctx.relative(path)))
          ctx.logger.info(ctx.relative(path))
        end
      end

      # Where the entry of the `index`-th `aqua:` item is written in dist/.
      def self.local_path(ctx : Context, index : Int32) : String
        ctx.dist_path("aqua", index > 0 ? "registry-#{index}.yaml" : "registry.yaml")
      end

      def registry(ctx : Context, aqua : Config::Aqua) : String
        archives = ctx.artifacts.filter(type: Artifact::Type::Archive).select { |artifact| artifact.extra["format"]? == "tar.gz" }
        raise PackageError.new("aqua: no tar.gz archive to point to") if archives.empty?
        version = ctx.version_info.version
        templates = archives.map { |archive| aqua_template(archive.name, version, archive.os, archive.arch) }.uniq!
        unless templates.size == 1
          raise PackageError.new("aqua: the archive names do not follow one template: #{templates.join(", ")}")
        end
        first = archives.first
        wrap = first.extra["wrap"]?.presence.try { |dir| aqua_template(dir, version, first.os, first.arch) }
        binaries = (first.extra["binaries"]? || "").split(',').reject(&.empty?)
        aliases = (first.extra["aliases"]? || "").split(',').reject(&.empty?).map(&.partition('='))
        # Each alias is listed under its binary: one whose binary is not in
        # the archive would be dropped from the entry without a word.
        aliases.each do |(name, _, target)|
          next if binaries.includes?(target)
          raise PackageError.new("aqua: the alias #{name} points at #{target}, which is not a binary of #{first.name}")
        end
        checksum = ctx.artifacts.filter(type: Artifact::Type::Checksum).first?
        owner, repo = repository(ctx)

        checksum_asset = checksum.try do |file|
          # Split checksums: one file per asset, named after it.
          ctx.config.checksum.split? ? "{{.Asset}}#{Checksum::SPLIT_SUFFIX}" : aqua_template(file.name, version, nil, nil)
        end
        String.build do |io|
          io << SCHEMA_COMMENT << "\n"
          io << "packages:\n"
          io << "  - type: github_release\n"
          io << "    repo_owner: " << scalar(owner) << "\n"
          io << "    repo_name: " << scalar(repo) << "\n"
          io << "    description: " << scalar(aqua.description) << "\n" unless aqua.description.empty?
          # A string: aqua evaluates it as an expression.
          io << "    version_constraint: \"true\"\n"
          io << "    asset: " << scalar(templates.first) << "\n"
          io << "    format: tar.gz\n"
          io << "    files:\n"
          binaries.each do |binary|
            io << "      - name: " << scalar(binary) << "\n"
            io << "        src: " << scalar("#{wrap}/#{binary}") << "\n" if wrap
            # A symbolic link in the archive: its src is the binary it names.
            aliases.each do |(name, _, target)|
              next unless target == binary
              io << "      - name: " << scalar(name) << "\n"
              io << "        src: " << scalar(wrap ? "#{wrap}/#{binary}" : binary) << "\n"
            end
          end
          io << "    supported_envs:\n"
          supported_envs(archives).each { |env| io << "      - " << scalar(env) << "\n" }
          if checksum_asset
            io << "    checksum:\n"
            io << "      type: github_release\n"
            io << "      asset: " << scalar(checksum_asset) << "\n"
            io << "      algorithm: sha256\n"
          end
        end
      end

      # Every entry of aqua's own registry starts with it: editors validate
      # the file against the registry schema.
      SCHEMA_COMMENT = "# yaml-language-server: $schema=https://raw.githubusercontent.com/aquaproj/aqua/main/json-schema/registry.json"

      # What YAML 1.1, which the readers of a registry still follow, takes
      # for a boolean or for nothing when written bare.
      RESERVED = /\A(y|n|yes|no|on|off|true|false|null|~)\z/i

      # Plain text YAML reads back as the same string; anything else is
      # double-quoted, in JSON syntax, which is also YAML's.
      private def scalar(value : String) : String
        plain = value.matches?(/\A[A-Za-z0-9][A-Za-z0-9 _.\/+@-]*\z/) && !value.ends_with?(' ') &&
                !value.matches?(RESERVED) && YAML::Schema::Core.parse_scalar(value).is_a?(String)
        plain ? value : value.to_json
      end

      # An archive name with the version, os and arch replaced by aqua's
      # template expressions. For the os and the arch: whole words only (so
      # "toy-amd64ish" is safe), and the last occurrence only, which is the
      # one the name template wrote; a project called "linux-tool" keeps its
      # name on every platform.
      private def aqua_template(name : String, version : String, os : String?, arch : String?) : String
        result = name.gsub(version, "{{trimV .Version}}")
        result = replace_last_word(result, os, "{{.OS}}") if os
        result = replace_last_word(result, arch, "{{.Arch}}") if arch
        result
      end

      private def replace_last_word(text : String, word : String, replacement : String) : String
        last = nil
        text.scan(/(?<![A-Za-z0-9])#{Regex.escape(word)}(?![A-Za-z0-9])/) { |match| last = match }
        found = last
        return text unless found
        text[0, found.begin(0)] + replacement + text[found.end(0)..]
      end

      # "linux" when both architectures are there, "linux/amd64" otherwise.
      private def supported_envs(archives : Array(Artifact)) : Array(String)
        by_os = archives.group_by(&.os.to_s)
        by_os.keys.sort!.flat_map do |system|
          arches = by_os[system].compact_map(&.arch).uniq!.sort!
          arches == ["amd64", "arm64"] ? [system] : arches.map { |arch| "#{system}/#{arch}" }
        end
      end

      private def repository(ctx : Context) : {String, String}
        ctx.release_repo
      rescue error : ConfigError
        raise error if Homebrew.publishing?(ctx)
        {"OWNER", "REPO"}
      end
    end

    # Pushes the entries the aqua pipe wrote to their registry, once the
    # release they point at is published. Same name as that pipe, so that
    # --skip=aqua covers both.
    class AquaPush < PublishPipe
      def name : String
        "aqua"
      end

      def description : String
        "pushing the aqua registry entry"
      end

      def skip?(ctx : Context) : String?
        return "no aqua configured" if ctx.config.aqua.empty?
        Homebrew.push_skipped?(ctx, "the registry entry")
      end

      def run(ctx : Context) : Nil
        ctx.config.aqua.each_with_index do |aqua, index|
          next unless Homebrew.pushing?(ctx, aqua.path, aqua.skip_upload)
          push(ctx, aqua, index, File.read(Aqua.local_path(ctx, index)))
        end
      end

      private def push(ctx : Context, aqua : Config::Aqua, index : Int32, registry : String) : Nil
        repository = aqua.repository
        client = ctx.repository_client(repository, "aqua[#{index}].repository")
        sha = client.file_sha(repository.owner, repository.name, aqua.path, repository.branch)
        client.put_file(repository.owner, repository.name, aqua.path, repository.branch, registry,
          "Aqua registry update for #{ctx.config.project_name} version #{ctx.version_info.tag}", sha)
        ctx.logger.info("pushed #{aqua.path}", repo: "#{repository.owner}/#{repository.name}")
      end
    end
  end
end
