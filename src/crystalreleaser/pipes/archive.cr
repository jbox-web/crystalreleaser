require "compress/gzip"

require "../artifact"
require "../context"
require "../formats/tar"
require "../formats/zip"
require "../pipe"

module Crystalreleaser
  module Pipes
    # One archive per (archive config, os, arch): the binaries of the listed
    # builds plus the `files:` globs. Reproducible, tar.gz and zip alike:
    # members sorted, owned by root, stamped with the commit time, gzip
    # header stamped likewise. Symbolic links are followed: the archive holds
    # the content they point to. A `files:` entry that is a directory is
    # archived whole, hidden files included.
    #
    # The `binary` format is no archive at all: the binary itself, under the
    # rendered name, for the projects whose users download one file and run
    # it. The `files:` have nowhere to go and are left out.
    class Archive < Pipe
      # A file to put in an archive; `source` nil means a directory entry,
      # unless `link` is set: then it is a symbolic link to that target.
      record Member, path : String, mode : Int32, source : String?, link : String? = nil

      def name : String
        "archive"
      end

      def description : String
        "archiving"
      end

      def skip?(ctx : Context) : String?
        "no binaries to archive" if ctx.artifacts.filter(type: Artifact::Type::Binary).empty?
      end

      def run(ctx : Context) : Nil
        names = Set(String).new
        ctx.config.archives.each_with_index do |archive, index|
          binaries = ctx.artifacts.filter(type: Artifact::Type::Binary)
            .select { |artifact| archive.builds.includes?(artifact.build_id) }
          binaries.group_by { |artifact| {artifact.os || "", artifact.arch || ""} }.each do |(os, arch), group|
            formats_for(archive, os).each do |format|
              build_archive(ctx, archive, index, os, arch, group, format, names)
            end
          end
        end
      end

      private def formats_for(archive : Config::Archive, os : String) : Array(String)
        archive.format_overrides.find { |override| override.os == os }.try(&.formats) || archive.formats
      end

      private def build_archive(ctx : Context, archive : Config::Archive, index : Int32, os : String, arch : String,
                                binaries : Array(Artifact), format : String, names : Set(String)) : Nil
        vars = ctx.vars.merge({
          "Os"     => os,
          "Arch"   => arch,
          "Target" => binaries.first.extra["target"]? || "",
          "Binary" => binaries.first.name,
        })
        base = ctx.render(archive.name_template, "archives[#{index}].name_template", vars)
        bare = format == "binary"
        file_name = ctx.file_name(bare ? base : "#{base}.#{format}", "archives[#{index}].name_template")
        unless names.add?(file_name)
          raise PackageError.new("archives[#{index}]: two archives would be named #{file_name}; " \
                                 "add .Os and .Arch to name_template")
        end

        path = ctx.dist_path(file_name)
        wrap = archive.wrap_in_directory? && !bare ? base : nil
        # Symbolic links only exist in tar.gz; the validator has refused
        # aliases for the other formats.
        links = format == "tar.gz" ? alias_links(binaries) : [] of {String, String}
        if bare
          write_binary(ctx, index, path, binaries, os, arch)
        else
          members = members(ctx, archive, index, binaries, links, wrap, file_name)
          format == "zip" ? write_zip(path, members, ctx.commit_time) : write_tar_gz(path, members, ctx.commit_time)
        end

        ctx.logger.info(file_name)
        extra = {"format" => format, "binaries" => binaries.join(',', &.name), "wrap" => wrap || ""}
        # `alias=binary` pairs, for the aqua pipe; absent without aliases.
        extra["aliases"] = links.map { |(name, target)| "#{name}=#{target}" }.join(',') unless links.empty?
        ctx.artifacts.add(Artifact.new(Artifact::Type::Archive, file_name, ctx.relative(path),
          os: os, arch: arch, size: File.size(path), extra: extra))
      end

      # {alias, binary} for every alias the builds of this platform declared,
      # in the order they were written.
      private def alias_links(binaries : Array(Artifact)) : Array({String, String})
        binaries.flat_map do |binary|
          (binary.extra["aliases"]? || "").split(',').reject(&.empty?).map { |name| {name, binary.name} }
        end
      end

      # The `binary` format: a copy of the one binary of the platform.
      private def write_binary(ctx : Context, index : Int32, path : String, binaries : Array(Artifact),
                               os : String, arch : String) : Nil
        unless binaries.size == 1
          raise PackageError.new("archives[#{index}]: the binary format publishes one binary per platform, " \
                                 "#{os}/#{arch} has #{binaries.size} (#{binaries.join(", ", &.name)}): " \
                                 "give each build an archive of its own with builds:")
        end
        # An archive has an extension; a bare name may well be the one of
        # the folder the build left the binary in.
        if File.exists?(path)
          raise PackageError.new("archives[#{index}]: #{ctx.relative(path)} already exists (the folder of a build?): " \
                                 "change name_template")
        end
        write_output(path) do |file|
          File.open(File.join(ctx.dir, binaries.first.path)) { |source| IO.copy(source, file) }
        end
        File.chmod(path, 0o755)
      end

      # Files, binaries and aliases, sorted, each preceded by the directories
      # that lead to it.
      private def members(ctx : Context, archive : Config::Archive, index : Int32, binaries : Array(Artifact),
                          links : Array({String, String}), wrap : String?, file_name : String) : Array(Member)
        files = {} of String => Member
        add = ->(member : Member) do
          if previous = files[member.path]?
            # Two globs matching the same file is not a conflict.
            unless previous.source == member.source && previous.link == member.link
              raise PackageError.new("archives[#{index}]: #{member.path} appears twice in #{file_name}")
            end
          end
          files[member.path] = member
        end

        extra_files(ctx, archive, index).each { |member| add.call(member) }
        binaries.each { |binary| add.call(Member.new(binary.name, 0o755, File.join(ctx.dir, binary.path))) }
        # Beside the binary, and relative to it: the link stays valid wherever
        # the archive is extracted. 0777 is what a symbolic link has anyway.
        links.each { |(name, target)| add.call(Member.new(name, 0o777, nil, target)) }

        result = [] of Member
        seen_dirs = Set(String).new
        result << Member.new("#{wrap}/", 0o755, nil) if wrap
        files.keys.sort!.each do |relative|
          parts = relative.split('/')
          (1...parts.size).each do |depth|
            dir = parts[0, depth].join('/')
            result << Member.new(prefixed(wrap, "#{dir}/"), 0o755, nil) if seen_dirs.add?(dir)
          end
          member = files[relative]
          result << Member.new(prefixed(wrap, relative), member.mode, member.source, member.link)
        end
        result
      end

      private def prefixed(wrap : String?, path : String) : String
        wrap ? "#{wrap}/#{path}" : path
      end

      # The `files:` globs, resolved in the project directory. Anything under
      # dist/ is left out, so a broad glob never archives a previous output:
      # paths are normalized first (`./*` matches `<project>/./dist`), and
      # every file is checked, not only the glob match (`.` matches the
      # project, dist/ included).
      private def extra_files(ctx : Context, archive : Config::Archive, index : Int32) : Array(Member)
        dist = ctx.dist_path
        members = [] of Member
        # The project path is not part of the pattern: its own `[`, `{` or
        # `*` must not be read as glob syntax.
        root = ctx.dir.gsub(/[\\*?\[\]{}]/) { |char| "\\#{char}" }
        archive.file_specs.each do |spec|
          matches = Dir.glob(File.join(root, spec.src)).map { |match| File.expand_path(match) }.uniq!.sort!
          # A pattern may well match nothing; a plain name that does is a typo.
          if matches.empty? && !spec.src.matches?(/[*?\[{]/)
            ctx.logger.warn("archives[#{index}].files: #{spec.src} matches no file")
          end
          matches.each do |match|
            parent = File.dirname(match)
            files_under(ctx, match, index).each do |file|
              next if file == dist || file.starts_with?("#{dist}/")
              relative =
                if dst = spec.dst
                  File.join(dst, Path[file].relative_to(parent).to_s)
                else
                  ctx.relative(file)
                end
              if relative.starts_with?('/') || relative.split('/').includes?("..")
                raise PackageError.new("archives[#{index}].files: #{relative} would be extracted outside the archive")
              end
              members << Member.new(relative, executable?(file) ? 0o755 : 0o644, file)
            end
          end
        end
        members
      end

      # Every file under `path`, hidden ones included, through the symbolic
      # links to directories: a directory entry means all of it. `ancestors`
      # holds the real paths of the directories being walked, which is what
      # stops a link that leads back up.
      private def files_under(ctx : Context, path : String, index : Int32,
                              ancestors : Array(String) = [] of String) : Array(String)
        unless File.exists?(path)
          # A glob only matches what is there: this is a link to nothing.
          raise PackageError.new("archives[#{index}].files: #{ctx.relative(path)} is a broken symbolic link")
        end
        return [path] unless File.directory?(path)
        real = File.realpath(path)
        if ancestors.any? { |ancestor| ancestor == real || ancestor.starts_with?("#{real}/") }
          raise PackageError.new("archives[#{index}].files: #{ctx.relative(path)} is a symbolic link to a directory that contains it")
        end
        ancestors.push(real)
        files = Dir.children(path).sort!.flat_map { |child| files_under(ctx, File.join(path, child), index, ancestors) }
        ancestors.pop
        files
      end

      # Only the executable bit is kept: anything else in the source mode
      # (group write, odd umasks) would make the archive depend on the
      # checkout.
      private def executable?(path : String) : Bool
        File.info(path).permissions.value & 0o111 != 0
      end

      private def write_tar_gz(path : String, members : Array(Member), mtime : Time) : Nil
        write_output(path) do |file|
          gzip = Compress::Gzip::Writer.new(file)
          gzip.header.modification_time = mtime
          tar = Formats::Tar::Writer.new(gzip)
          members.each do |member|
            if source = member.source
              tar.add_file(member.path, member.mode, mtime, source)
            elsif link = member.link
              tar.add_symlink(member.path, link, mtime)
            else
              tar.add_directory(member.path, mtime, member.mode)
            end
          end
          tar.close
          gzip.close
        end
      end

      private def write_zip(path : String, members : Array(Member), mtime : Time) : Nil
        write_output(path) do |file|
          zip = Formats::Zip::Writer.new(file)
          members.each do |member|
            if source = member.source
              zip.add_file(member.path, member.mode, mtime, source)
            else
              zip.add_directory(member.path, member.mode, mtime)
            end
          end
          zip.close
        end
      end
    end
  end
end
