require "digest/sha256"

require "../artifact"
require "../context"
require "../pipe"

module Crystalreleaser
  module Pipes
    # checksums.txt in `sha256sum` format (`<hash>  <name>`, sorted by name)
    # over the archives and packages: what users download. With
    # `checksum.split`, one `<asset>.sha256` per asset instead, each holding
    # the line of its asset.
    class Checksum < Pipe
      TYPES = {Artifact::Type::Archive, Artifact::Type::LinuxPackage}

      def name : String
        "checksum"
      end

      def description : String
        "calculating checksums"
      end

      def skip?(ctx : Context) : String?
        "no archives or packages" if targets(ctx).empty?
      end

      def run(ctx : Context) : Nil
        lines = targets(ctx).sort_by(&.name).map do |artifact|
          hash = Checksum.sha256(File.join(ctx.dir, artifact.path))
          artifact.sha256 = hash
          {artifact.name, "#{hash}  #{artifact.name}\n"}
        end
        if ctx.config.checksum.split?
          lines.each { |(name, line)| write(ctx, "#{name}#{SPLIT_SUFFIX}", line) }
        else
          file_name = ctx.file_name(ctx.render(ctx.config.checksum.name_template, "checksum.name_template"),
            "checksum.name_template")
          write(ctx, file_name, lines.join { |(_, line)| line })
        end
      end

      # What a split checksum file adds to the name of its asset.
      SPLIT_SUFFIX = ".sha256"

      private def write(ctx : Context, file_name : String, content : String) : Nil
        if ctx.artifacts.all.any? { |artifact| artifact.name == file_name }
          raise PackageError.new("checksum: two artifacts would be named #{file_name}")
        end
        path = ctx.dist_path(file_name)
        File.write(path, content)
        ctx.logger.info(file_name)
        ctx.artifacts.add(Artifact.new(Artifact::Type::Checksum, file_name, ctx.relative(path), size: File.size(path)))
      end

      private def targets(ctx : Context) : Array(Artifact)
        ctx.artifacts.all.select { |artifact| TYPES.includes?(artifact.type) }
      end

      # Streams the file through the digest.
      def self.sha256(path : String) : String
        digest = Digest::SHA256.new
        File.open(path) do |file|
          buffer = Bytes.new(64 * 1024)
          while (read = file.read(buffer)) > 0
            digest.update(buffer[0, read])
          end
        end
        digest.hexfinal
      end
    end
  end
end
