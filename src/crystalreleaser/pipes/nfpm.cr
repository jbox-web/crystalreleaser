require "../artifact"
require "../builders/builder"
require "../context"
require "../formats/deb"
require "../formats/package"
require "../formats/rpm"
require "../gpg"
require "../pipe"

module Crystalreleaser
  module Pipes
    # .deb and .rpm packages of the Linux binaries, written natively (no
    # nfpm, no dpkg-deb, no rpmbuild): the binaries go to `bindir`, with
    # their aliases as symbolic links beside them, the `contents` entries
    # where they say. With `rpm.signature`, the .rpm packages are signed, by
    # gpg, and the public key joins the artifacts.
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
          next if binaries.empty?
          with_signer(ctx, nfpm, index) do |signer|
            # Dated at the commit, as the files of the package are: a release
            # run again writes the same .rpm, byte for byte, and so finds the
            # assets it already uploaded unchanged.
            sign = signer.try { |gpg| ->(data : Bytes) { gpg.sign(data, ctx.commit_time) } }
            binaries.group_by { |artifact| artifact.arch || "" }.each do |arch, group|
              nfpm.formats.each { |format| package(ctx, nfpm, index, arch, group, format, sign) }
            end
            publish_key(ctx, nfpm, index, signer) if signer
          end
        end
      end

      # Yields what signs the .rpm packages of the entry, or nil when they are
      # not signed: no `rpm.signature`, no rpm format, or a snapshot run
      # without the key.
      #
      # The key is resolved before any package is written: see
      # Context#signing_key for what a release and a snapshot each get.
      private def with_signer(ctx : Context, nfpm : Config::Nfpm, index : Int32, & : Gpg? ->) : Nil
        field = "nfpms[#{index}].rpm.signature"
        signature = nfpm.rpm.signature
        unless signature && nfpm.formats.includes?("rpm")
          yield nil
          return
        end
        key = ctx.signing_key(signature.key, "#{field}.key")
        unless key
          ctx.logger.warn("#{field}: no key in this snapshot, the .rpm packages are not signed")
          yield nil
          return
        end
        passphrase = ctx.render(signature.passphrase, "#{field}.passphrase")
        begin
          Gpg.open(key, passphrase) { |gpg| yield gpg }
        rescue error : Gpg::Error
          raise PackageError.new("#{field}: #{error.message}")
        end
      end

      # The public half of the key, next to the packages it signed: what
      # their users give to `rpm --import`. Exported from the key that signed,
      # so it cannot be another one. Named as the key files of a distribution
      # are (/etc/pki/rpm-gpg/RPM-GPG-KEY-*).
      private def publish_key(ctx : Context, nfpm : Config::Nfpm, index : Int32, gpg : Gpg) : Nil
        field = "nfpms[#{index}].rpm.signature"
        file_name = ctx.file_name("RPM-GPG-KEY-#{nfpm.package_name}", "nfpms[#{index}].package_name")
        path = ctx.dist_path(file_name)
        public_key = gpg.public_key
        if existing = ctx.artifacts.all.find { |artifact| artifact.name == file_name }
          # Two entries of one package name signed with the same key.
          return if existing.type.public_key? && File.read(path) == public_key
          raise PackageError.new("#{field}: #{file_name} already holds another key; give this entry its own package_name")
        end
        File.write(path, public_key)
        ctx.logger.info(file_name)
        ctx.artifacts.add(Artifact.new(Artifact::Type::PublicKey, file_name, ctx.relative(path), size: File.size(path)))
      end

      private def package(ctx : Context, nfpm : Config::Nfpm, index : Int32, arch : String,
                          binaries : Array(Artifact), format : String, sign : Formats::Rpm::Signer?) : Nil
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
          format == "rpm" ? Formats::Rpm.write(file, spec, sign) : Formats::Deb.write(file, spec)
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
          # The aliases the build recorded on its binary, beside it in bindir:
          # the target is the binary's bare name, valid wherever bindir is.
          (binary.extra["aliases"]? || "").split(',').reject(&.empty?).each do |name|
            spec.files << Formats::PackageSpec::File.symlink(File.join(nfpm.bindir, name), binary.name)
          end
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
