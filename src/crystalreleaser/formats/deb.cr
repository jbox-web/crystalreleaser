require "compress/gzip"
require "digest/md5"

require "./ar"
require "./buffer"
require "./package"
require "./tar"

module Crystalreleaser
  module Formats
    # A binary .deb: an ar archive of `debian-binary` (2.0), control.tar.gz
    # (control, md5sums, and conffiles when the package has configuration
    # files) and data.tar.gz (the files and symbolic links, every parent
    # directory listed explicitly, paths as ./usr/bin/...).
    module Deb
      ARCHES = {"amd64" => "amd64", "arm64" => "arm64"}

      def self.write(io : IO, spec : PackageSpec) : Nil
        ar = Ar::Writer.new(io)
        ar.add("debian-binary", "2.0\n".to_slice, spec.mtime)
        ar.add("control.tar.gz", control_tar(spec), spec.mtime)
        ar.add("data.tar.gz", data_tar(spec), spec.mtime)
      end

      def self.control(spec : PackageSpec) : String
        arch = ARCHES[spec.arch]? || raise FormatError.new("no Debian architecture for #{spec.arch}")
        fields = [
          {"Package", spec.name},
          {"Version", spec.package_version},
          {"Section", spec.section},
          {"Priority", spec.priority},
          {"Architecture", arch},
          {"Maintainer", spec.maintainer},
          {"Installed-Size", ((spec.installed_size + 1023) // 1024).to_s},
          {"Depends", spec.dependencies.join(", ") { |dependency| dependency(dependency) }},
          {"Homepage", spec.homepage},
        ]
        # A line break in one of these would start a field of its own.
        fields.each do |(key, value)|
          raise FormatError.new("control field #{key} must be a single line") if value.includes?('\n')
        end
        fields << {"Description", description(spec)}
        fields.reject { |(_, value)| value.empty? }.join { |(key, value)| "#{key}: #{value}\n" }
      end

      # `name (>= 1.0)`; Debian spells the strict comparisons `<<` and `>>`.
      private def self.dependency(text : String) : String
        name, operator, version = PackageSpec.parse_dependency(text)
        return name if operator.empty?
        "#{name} (#{{"<" => "<<", ">" => ">>"}[operator]? || operator} #{version})"
      end

      # The summary on the first line, the rest indented by one space, blank
      # lines written " ." as Debian policy requires.
      private def self.description(spec : PackageSpec) : String
        lines = spec.description.strip.lines
        return spec.summary if lines.size <= 1
        ([spec.summary] + lines[1..].map { |line| line.strip.empty? ? " ." : " #{line.rstrip}" }).join('\n')
      end

      # Regular files only: a symbolic link has no content of its own.
      def self.md5sums(spec : PackageSpec) : String
        spec.files.reject(&.symlink?).join do |file|
          digest = Digest::MD5.new
          digest.file(file.src)
          "#{digest.hexfinal}  #{file.dst.lchop('/')}\n"
        end
      end

      # The configuration files, one absolute path per line: what dpkg does
      # not overwrite once the administrator has changed them.
      def self.conffiles(spec : PackageSpec) : String
        spec.files.select(&.kind.config?).map(&.dst).sort!.join { |path| "#{path}\n" }
      end

      private def self.control_tar(spec : PackageSpec) : Bytes
        gzip_tar(spec.mtime) do |tar|
          tar.add_directory("./", spec.mtime)
          tar.add_file("./control", 0o644, spec.mtime, control(spec).to_slice)
          tar.add_file("./md5sums", 0o644, spec.mtime, md5sums(spec).to_slice)
          conffiles = conffiles(spec)
          tar.add_file("./conffiles", 0o644, spec.mtime, conffiles.to_slice) unless conffiles.empty?
        end
      end

      private def self.data_tar(spec : PackageSpec) : Bytes
        gzip_tar(spec.mtime) do |tar|
          tar.add_directory("./", spec.mtime)
          spec.directories.each { |dir| tar.add_directory(".#{dir}/", spec.mtime) }
          spec.files.sort_by(&.dst).each do |file|
            if link = file.link
              tar.add_symlink(".#{file.dst}", link, spec.mtime)
            else
              tar.add_file(".#{file.dst}", file.mode, spec.mtime, file.src)
            end
          end
        end
      end

      private def self.gzip_tar(mtime : Time, & : Tar::Writer ->) : Bytes
        io = Buffer.new("the content of the .deb package")
        gzip = Compress::Gzip::Writer.new(io)
        gzip.header.modification_time = mtime
        tar = Tar::Writer.new(gzip)
        yield tar
        tar.close
        gzip.close
        io.to_slice
      end
    end
  end
end
