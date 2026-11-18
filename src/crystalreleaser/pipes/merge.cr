require "json"

require "../artifact"
require "../context"
require "../pipe"
require "./checksum"

module Crystalreleaser
  module Pipes
    # release --merge: instead of building, reads back the binaries that
    # `build --split` runs left in dist/<os>_<arch>/, checks they come from
    # this very commit, and that every configured platform is there.
    class Merge < Pipe
      def name : String
        "merge"
      end

      def description : String
        "merging split builds"
      end

      def skippable? : Bool
        false
      end

      def run(ctx : Context) : Nil
        # Not a glob: the project path is not a pattern.
        dist = ctx.dist_path
        folders = Dir.exists?(dist) ? Dir.children(dist).sort! : [] of String
        parts = folders.map { |folder| File.join(dist, folder, "artifacts.json") }.select { |path| File.file?(path) }
        raise BuildError.new("no split build found: expected #{ctx.config.dist}/<os>_<arch>/artifacts.json") if parts.empty?

        parts.each { |path| merge_part(ctx, path) }
        check_coverage(ctx)
      end

      private def merge_part(ctx : Context, path : String) : Nil
        folder = Path[path].parent
        name = "#{ctx.config.dist}/#{folder.basename}"
        metadata = JSON.parse(File.read(folder.join("metadata.json").to_s)).as_h? ||
                   raise BuildError.new("cannot read the split build in #{name}: metadata.json is not an object")
        commit = metadata["commit"]?.try(&.as_s?) || raise BuildError.new("cannot read the split build in #{name}: metadata.json has no commit")
        version = metadata["version"]?.try(&.as_s?) || raise BuildError.new("cannot read the split build in #{name}: metadata.json has no version")
        if commit != ctx.commit
          raise BuildError.new("#{name} was built from commit #{commit}, HEAD is #{ctx.commit}")
        end
        if version != ctx.version_info.version
          raise BuildError.new("#{name} was built as version #{version}, this release is #{ctx.version_info.version}")
        end

        Array(Artifact).from_json(File.read(path)).each do |artifact|
          file = File.expand_path(artifact.path, ctx.dir)
          check_file(artifact, file, name, File.expand_path(folder.to_s))
          check_record(artifact, name, metadata)
          check_content(artifact, file, name)
          File.chmod(file, 0o755)
          ctx.artifacts.add(artifact)
          ctx.logger.info(artifact.path, build: artifact.build_id || "")
        end
      rescue error : File::NotFoundError | JSON::ParseException
        raise BuildError.new("cannot read the split build in #{ctx.config.dist}/#{Path[path].parent.basename}: #{error.message}")
      end

      # artifacts.json comes from another machine: it only gets to name
      # files of its own folder, which are then made executable.
      private def check_file(artifact : Artifact, file : String, name : String, folder : String) : Nil
        raise BuildError.new("#{name}: #{artifact.path} is outside this split build") unless file.starts_with?("#{folder}/")
        # The check above is on the text of the path: a link inside the
        # folder may lead anywhere, and chmod follows it.
        raise BuildError.new("#{name}: #{artifact.path} is a symbolic link") if File.symlink?(file)
        raise BuildError.new("#{name}: #{artifact.path} is listed but missing") unless File.file?(file)
      end

      # The file is the one its runner built: same size, same sha256. The
      # size alone would let through a file changed in transit that kept its
      # length; it is checked first because its message says what happened.
      private def check_content(artifact : Artifact, file : String, name : String) : Nil
        if (built = artifact.size) && File.size(file) != built
          raise BuildError.new("#{name}: #{artifact.path} is #{File.size(file)} bytes, #{built} were built: incomplete transfer?")
        end
        recorded = artifact.sha256 || raise BuildError.new("#{name}: #{artifact.path} has no sha256 recorded")
        unless Checksum.sha256(file) == recorded
          raise BuildError.new("#{name}: #{artifact.path} does not have the sha256 its runner recorded")
        end
      end

      # artifacts.json is only believed as far as it describes a binary of
      # the platform its folder was built for.
      private def check_record(artifact : Artifact, name : String, metadata : Hash(String, JSON::Any)) : Nil
        unless artifact.type.binary?
          raise BuildError.new("#{name}: #{artifact.path} is recorded as #{artifact.type.to_s.underscore}, not as a binary")
        end
        if artifact.name.empty? || artifact.name.includes?('/') || artifact.name.in?(".", "..")
          raise BuildError.new("#{name}: #{artifact.path} is named #{artifact.name.inspect}, which is not a plain name")
        end
        check_recorded_aliases(artifact, name)
        os = metadata["os"]?.try(&.as_s?)
        arch = metadata["arch"]?.try(&.as_s?)
        return unless os && arch
        unless artifact.os == os && artifact.arch == arch
          raise BuildError.new("#{name}: #{artifact.path} is recorded for #{artifact.os}/#{artifact.arch} in a #{os}/#{arch} build")
        end
      end

      # They become member names of the archive, and names of the aqua
      # entry: one given twice would be written twice in both, and one
      # named as the binary would replace it. Compared without case: the
      # default macOS file system ignores it.
      private def check_recorded_aliases(artifact : Artifact, name : String) : Nil
        seen = Set(String).new
        (artifact.extra["aliases"]? || "").split(',').reject(&.empty?).each do |alias_name|
          if !Config::Build.alias_name?(alias_name)
            raise BuildError.new("#{name}: #{artifact.path} lists the alias #{alias_name.inspect}, which is not an alias name")
          end
          if alias_name.downcase == artifact.name.downcase
            raise BuildError.new("#{name}: #{artifact.path} lists the alias #{alias_name.inspect}, which is the binary's own name")
          end
          unless seen.add?(alias_name.downcase)
            raise BuildError.new("#{name}: #{artifact.path} lists the alias #{alias_name.inspect} twice")
          end
        end
      end

      # Every (build, platform) of the config must be present, windows aside.
      private def check_coverage(ctx : Context) : Nil
        present = ctx.artifacts.filter(type: Artifact::Type::Binary).map { |artifact| {artifact.build_id, artifact.os, artifact.arch} }
        missing = [] of String
        ctx.config.builds.each do |build|
          build.platforms.each do |platform|
            next if platform.os == "windows"
            next if present.includes?({build.id, platform.os, platform.arch})
            missing << "#{build.id} #{platform.os}/#{platform.arch}"
          end
        end
        return if missing.empty?
        message = "missing platforms: #{missing.join(", ")}"
        raise BuildError.new("#{message} (use --allow-missing to release without them)") unless ctx.options.allow_missing?
        ctx.logger.warn(message)
      end
    end
  end
end
