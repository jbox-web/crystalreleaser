require "../artifact"
require "../builders/builder"
require "../context"
require "../formats/deb"
require "../formats/package"
require "../formats/rpm"
require "../pipe"

module Crystalreleaser
  module Pipes
    # .deb and .rpm packages of the Linux binaries, written natively (no
    # nfpm, no dpkg-deb, no rpmbuild): the binaries go to `bindir`, the
    # `contents` entries where they say.
    class Nfpm < Pipe
      def name : String
        "nfpm"
      end

      def description : String
        "building Linux packages"
      end

      def skip?(ctx : Context) : String?
        return "no nfpms configured" if ctx.config.nfpms.empty?
        "no linux binaries" if ctx.artifacts.filter(type: Artifact::Type::Binary, os: "linux").empty?
      end

      def run(ctx : Context) : Nil
        ctx.config.nfpms.each_with_index do |nfpm, index|
          binaries = ctx.artifacts.filter(type: Artifact::Type::Binary, os: "linux")
            .select { |artifact| nfpm.builds.includes?(artifact.build_id) }
          binaries.group_by { |artifact| artifact.arch || "" }.each do |arch, group|
            nfpm.formats.each { |format| package(ctx, nfpm, index, arch, group, format) }
          end
        end
      end

      private def package(ctx : Context, nfpm : Config::Nfpm, index : Int32, arch : String,
                          binaries : Array(Artifact), format : String) : Nil
        spec = package_spec(ctx, nfpm, index, arch, binaries)
        vars = ctx.vars.merge({
          "Os"          => "linux",
          "Arch"        => arch,
          "Target"      => binaries.first.extra["target"]? || "",
          "Binary"      => binaries.first.name,
          "PackageName" => nfpm.package_name,
        })
        file_name = ctx.file_name(ctx.render(nfpm.file_name_template, "nfpms[#{index}].file_name_template", vars) + ".#{format}",
          "nfpms[#{index}].file_name_template")
        # Checked against every artifact so far, archives included: a second
        # file of the same name would overwrite the first, and both artifacts
        # would then point at the content of the last one.
        if ctx.artifacts.all.any? { |artifact| artifact.name == file_name }
          raise PackageError.new("nfpms[#{index}]: two artifacts would be named #{file_name}; " \
                                 "add .Arch to file_name_template")
        end
        path = ctx.dist_path(file_name)
        write_output(path) do |file|
          format == "rpm" ? Formats::Rpm.write(file, spec) : Formats::Deb.write(file, spec)
        end
        ctx.logger.info(file_name)
        ctx.artifacts.add(Artifact.new(Artifact::Type::LinuxPackage, file_name, ctx.relative(path),
          os: "linux", arch: arch, size: File.size(path), extra: {"format" => format}))
      end

      private def package_spec(ctx : Context, nfpm : Config::Nfpm, index : Int32, arch : String,
                               binaries : Array(Artifact)) : Formats::PackageSpec
        spec = Formats::PackageSpec.new(nfpm.package_name, ctx.version_info.version, arch)
        spec.maintainer = nfpm.maintainer
        spec.description = nfpm.description
        spec.homepage = nfpm.homepage
        spec.license = nfpm.license
        spec.vendor = nfpm.vendor
        spec.section = nfpm.section
        spec.priority = nfpm.priority
        spec.dependencies = nfpm.dependencies
        spec.mtime = ctx.commit_time
        binaries.each do |binary|
          spec.files << Formats::PackageSpec::File.new(File.join(nfpm.bindir, binary.name),
            File.join(ctx.dir, binary.path), 0o755)
        end
        nfpm.contents.each_with_index do |content, position|
          source = File.expand_path(content.src, ctx.dir)
          unless File.file?(source)
            raise PackageError.new("nfpms[#{index}].contents[#{position}].src: file not found: #{content.src}")
          end
          mode = File.info(source).permissions.value & 0o111 != 0 ? 0o755 : 0o644
          kind =
            case content.type
            when "config"           then Formats::PackageSpec::Kind::Config
            when "config|noreplace" then Formats::PackageSpec::Kind::ConfigNoreplace
            else                         Formats::PackageSpec::Kind::Regular
            end
          spec.files << Formats::PackageSpec::File.new(content.dst, source, mode, kind)
        end
        if twice = spec.files.map(&.dst).tally.find { |_, count| count > 1 }
          raise PackageError.new("nfpms[#{index}]: #{twice[0]} is installed twice")
        end
        spec
      end
    end
  end
end
