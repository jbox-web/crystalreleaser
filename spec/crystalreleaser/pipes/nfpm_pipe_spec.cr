require "../../spec_helper"

private CONFIG = <<-YAML
  nfpms:
    - id: packages
      formats: [deb]
      maintainer: Jane Doe <jane@example.com>
      description: A toy
      bindir: /usr/local/bin
      contents:
        - src: LICENSE
          dst: /usr/share/doc/toy/LICENSE
  YAML

private SIGNED = <<-YAML
  nfpms:
    - id: packages
      formats: [deb, rpm]
      maintainer: Jane Doe <jane@example.com>
      description: A toy
      rpm:
        signature:
          key: "{{ .Env.RPM_SIGNING_KEY }}"
          passphrase: "{{ .Env.RPM_SIGNING_PASSPHRASE }}"
  YAML

private GPG_FIXTURES   = File.join(__DIR__, "../../fixtures/gpg")
private RSA_KEY        = File.read(File.join(GPG_FIXTURES, "rsa-secret.asc"))
private RSA_PASSPHRASE = "crystalreleaser-spec"

private def signature_header(path : String)
  File.open(path) { |file| Crystalreleaser::Formats::Rpm.read(file) }[1]
end

private def signature_tags(path : String) : Array(Int32)
  signature_header(path).keys.select(&.in?(267, 268))
end

private def signature_tags_of(package : Bytes) : Array(Int32)
  Crystalreleaser::Formats::Rpm.read(IO::Memory.new(package))[1].keys.select(&.in?(267, 268))
end

private def data_entries(path : String) : Array(Crystalreleaser::Formats::Tar::Entry)
  data = File.open(path) { |file| Crystalreleaser::Formats::Ar.read(file) }.last
  Compress::Gzip::Reader.open(IO::Memory.new(data.content)) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
end

private def rpm_header(path : String)
  File.open(path) { |file| Crystalreleaser::Formats::Rpm.read(file) }[2]
end

describe Crystalreleaser::Pipes::Nfpm do
  it "signs the .rpm packages with the key of the environment and adds the public key to the artifacts" do
    pending_tool!("gpg")
    Fixture.project(config: SIGNED) do |project|
      log = IO::Memory.new
      ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE}, log: log)
      fake_binary(ctx, "linux", "amd64")
      fake_binary(ctx, "linux", "arm64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      {"amd64", "arm64"}.each do |arch|
        signature_tags(project.path("dist/toy_1.2.3-rc.1_#{arch}.rpm")).should eq([268])
      end

      keys = ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::PublicKey)
      keys.map { |artifact| {artifact.name, artifact.path} }.should eq([{"RPM-GPG-KEY-toy", "dist/RPM-GPG-KEY-toy"}])
      public_key = File.read(project.path("dist/RPM-GPG-KEY-toy"))
      public_key.should start_with("-----BEGIN PGP PUBLIC KEY BLOCK-----\n")
      public_key.should_not contain("PRIVATE KEY")

      # The packages, in the order they were written, then the key.
      ctx.artifacts.all.reject(&.type.binary?).map(&.name).should eq([
        "toy_1.2.3-rc.1_amd64.deb", "toy_1.2.3-rc.1_amd64.rpm",
        "toy_1.2.3-rc.1_arm64.deb", "toy_1.2.3-rc.1_arm64.rpm",
        "RPM-GPG-KEY-toy",
      ])

      output = log.to_s
      output.should contain("RPM-GPG-KEY-toy")
      output.should_not contain(RSA_PASSPHRASE)
      RSA_KEY.lines.reject(&.empty?).each { |line| output.should_not contain(line) }
    end
  end

  it "has the signature of a package it signed verified by gpg" do
    pending_tool!("gpg")
    Fixture.project(config: SIGNED) do |project|
      ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE})
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      _, signature, _, header, _ = File.open(project.path("dist/toy_1.2.3-rc.1_amd64.rpm")) { |file| Crystalreleaser::Formats::Rpm.read(file) }
      home = File.join(Dir.tempdir, "crel-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir(home, 0o700)
      begin
        File.write(File.join(home, "header"), header)
        File.write(File.join(home, "header.sig"), signature[268].as(Bytes))
        # The key the pipe published, not the fixture: it must be the right one.
        run_tool(["gpg", "--homedir", home, "--batch", "--import", project.path("dist/RPM-GPG-KEY-toy")])
        run_tool(["gpg", "--homedir", home, "--batch", "--status-fd", "1", "--verify",
                  File.join(home, "header.sig"), File.join(home, "header")])
          .should contain("VALIDSIG 9BCB5C9D9BCDDC23B63C403FB7A81D331E802F50")
      ensure
        Process.run("gpgconf", ["--homedir", home, "--kill", "all"], error: Process::Redirect::Close)
        FileUtils.rm_rf(home)
      end
    end
  end

  # A release that failed halfway is run again: the assets already uploaded
  # must come out the same, or the run stops on a conflict.
  it "writes the same signed package when run again" do
    pending_tool!("gpg")
    packages = Array(Bytes).new(2) do
      content = Bytes.empty
      Fixture.project(config: SIGNED) do |project|
        ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE})
        fake_binary(ctx, "linux", "amd64")
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
        content = File.open(project.path("dist/toy_1.2.3-rc.1_amd64.rpm"), &.getb_to_end)
      end
      # gpg dates a signature to the second.
      sleep 1.1.seconds
      content
    end
    signature_tags_of(packages[0]).should eq([268])
    packages[1].should eq(packages[0])
  end

  it "leaves the packages unsigned, and publishes no key, without rpm.signature" do
    Fixture.project(config: SIGNED.lines.first(5).join("\n") + "\n") do |project|
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      signature_tags(project.path("dist/toy_1.2.3-rc.1_amd64.rpm")).should be_empty
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::PublicKey).should be_empty
      Dir.children(project.path("dist")).sort!.should eq(["toy_1.2.3-rc.1_amd64.deb", "toy_1.2.3-rc.1_amd64.rpm", "toy_linux_amd64"])
    end
  end

  it "does not ask for the key when the entry builds no .rpm" do
    Fixture.project(config: SIGNED.sub("formats: [deb, rpm]", "formats: [deb]")) do |project|
      # No key in the environment: rendering it would fail.
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      Dir.children(project.path("dist")).sort!.should eq(["toy_1.2.3-rc.1_amd64.deb", "toy_linux_amd64"])
    end
  end

  # A release whose secret is missing must not go out unsigned without a word.
  it "refuses to release unsigned packages when the key is missing or empty" do
    Fixture.project(config: SIGNED) do |project|
      ctx = spec_context(project, env: {"RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE})
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::TemplateError, "nfpms[0].rpm.signature.key: environment variable RPM_SIGNING_KEY is not set") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end

      ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => " \n", "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE})
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::ConfigError, "nfpms[0].rpm.signature.key: the key is empty") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
      Dir.children(project.path("dist")).should eq(["toy_linux_amd64"])
    end
  end

  # A snapshot is a rehearsal, on machines that do not hold the release key
  # (a pull request, a developer): it says so and goes on.
  it "warns and leaves the packages unsigned in a snapshot without the key" do
    Fixture.project(config: SIGNED) do |project|
      log = IO::Memory.new
      ctx = spec_context(project, log: log)
      ctx.version_info = Crystalreleaser::VersionInfo.snapshot("v1.2.2", "0123456")
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      rpm = Dir.glob(project.path("dist/*.rpm"))
      rpm.size.should eq(1)
      signature_tags(rpm.first).should be_empty
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::PublicKey).should be_empty
      log.to_s.should contain("nfpms[0].rpm.signature: no key in this snapshot, the .rpm packages are not signed")
    end
  end

  it "says which entry could not sign when gpg refuses the key" do
    pending_tool!("gpg")
    Fixture.project(config: SIGNED) do |project|
      ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => "wrong"})
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::PackageError, "nfpms[0].rpm.signature: gpg could not sign") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
      Dir.children(project.path("dist")).sort!.should eq(["toy_1.2.3-rc.1_amd64.deb", "toy_linux_amd64"])
    end
  end

  it "refuses two entries that would publish two different keys under one name" do
    pending_tool!("gpg")
    second = <<-YAML

        - id: other
          formats: [rpm]
          maintainer: Jane Doe <jane@example.com>
          file_name_template: "other_{{ .Arch }}"
          rpm:
            signature:
              key: "{{ .Env.OTHER_KEY }}"
      YAML
    Fixture.project(config: SIGNED + second) do |project|
      ctx = spec_context(project, env: {
        "RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE,
        "OTHER_KEY" => File.read(File.join(GPG_FIXTURES, "ed25519-secret.asc")),
      })
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::PackageError,
        "nfpms[1].rpm.signature: RPM-GPG-KEY-toy already holds another key; give this entry its own package_name") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
    end
  end

  it "publishes once the key two entries share" do
    pending_tool!("gpg")
    second = <<-YAML

        - id: other
          formats: [rpm]
          maintainer: Jane Doe <jane@example.com>
          file_name_template: "other_{{ .Arch }}"
          rpm:
            signature:
              key: "{{ .Env.RPM_SIGNING_KEY }}"
              passphrase: "{{ .Env.RPM_SIGNING_PASSPHRASE }}"
      YAML
    Fixture.project(config: SIGNED + second) do |project|
      ctx = spec_context(project, env: {"RPM_SIGNING_KEY" => RSA_KEY, "RPM_SIGNING_PASSPHRASE" => RSA_PASSPHRASE})
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::PublicKey).map(&.name).should eq(["RPM-GPG-KEY-toy"])
      signature_tags(project.path("dist/other_amd64.rpm")).should eq([268])
    end
  end

  it "installs each alias of a packaged build as a symbolic link to the binary, in bindir" do
    Fixture.project(config: CONFIG.sub("formats: [deb]", "formats: [deb, rpm]")) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64", aliases: ["toy-manager", "tm"])
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      deb = project.path("dist/toy_1.2.3-rc.1_amd64.deb")
      data_entries(deb).select(&.type.==('2')).map(&.name).should eq(["./usr/local/bin/tm", "./usr/local/bin/toy-manager"])
      # ustar: typeflag at 156, linkname at 157.
      data = project.path("data.tar.gz")
      File.write(data, File.open(deb) { |file| Crystalreleaser::Formats::Ar.read(file) }.last.content)
      {"./usr/local/bin/tm", "./usr/local/bin/toy-manager"}.each do |name|
        header = tar_header(data, name)
        header[156].chr.should eq('2')
        String.new(header[157, 4]).should eq("toy\0")
      end

      header = rpm_header(project.path("dist/toy_1.2.3-rc.1_amd64.rpm"))
      header[Crystalreleaser::Formats::Rpm::Tag::BASENAMES].should eq(["tm", "toy", "toy-manager", "toy", "LICENSE"])
      header[Crystalreleaser::Formats::Rpm::Tag::FILELINKTOS].should eq(["toy", "", "toy", "", ""])
    end
  end

  it "writes no symbolic link for a build without aliases" do
    Fixture.project(config: CONFIG.sub("formats: [deb]", "formats: [deb, rpm]")) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      data_entries(project.path("dist/toy_1.2.3-rc.1_amd64.deb")).map(&.type).uniq!.sort!.should eq(['0', '5'])
      header = rpm_header(project.path("dist/toy_1.2.3-rc.1_amd64.rpm"))
      header[Crystalreleaser::Formats::Rpm::Tag::FILELINKTOS].should eq(["", "", ""])
    end
  end

  it "refuses an alias installed over a content" do
    Fixture.project(config: CONFIG.sub("/usr/share/doc/toy/LICENSE", "/usr/local/bin/toy-manager")) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64", aliases: ["toy-manager"])
      expect_raises(Crystalreleaser::PackageError, "nfpms[0]: /usr/local/bin/toy-manager is installed twice") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
    end
  end

  it "packages each linux architecture, ignoring other systems" do
    Fixture.project(config: CONFIG) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      fake_binary(ctx, "linux", "arm64")
      fake_binary(ctx, "darwin", "arm64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::LinuxPackage).map { |artifact| {artifact.name, artifact.arch} }
        .should eq([{"toy_1.2.3-rc.1_amd64.deb", "amd64"}, {"toy_1.2.3-rc.1_arm64.deb", "arm64"}])

      data = File.open(project.path("dist/toy_1.2.3-rc.1_arm64.deb")) { |file| Crystalreleaser::Formats::Ar.read(file) }.last
      files = Compress::Gzip::Reader.open(IO::Memory.new(data.content)) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
        .select(&.type.==('0'))
      files.map { |entry| {entry.name, entry.mode, String.new(entry.content)} }.should eq([
        {"./usr/local/bin/toy", 0o755, "toy for linux/arm64"},
        {"./usr/share/doc/toy/LICENSE", 0o644, "MIT\n"},
      ])
    end
  end

  it "marks the contents of type config as configuration files of the package" do
    config = CONFIG + "\n      - src: toy.conf\n        dst: /etc/toy/toy.conf\n        type: config|noreplace\n"
    Fixture.project(config: config) do |project|
      project.write("LICENSE", "MIT\n")
      project.write("toy.conf", "verbose = no\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Nfpm.new.run(ctx)

      control = File.open(project.path("dist/toy_1.2.3-rc.1_amd64.deb")) { |file| Crystalreleaser::Formats::Ar.read(file) }[1]
      conffiles = Compress::Gzip::Reader.open(IO::Memory.new(control.content)) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
        .find!(&.name.==("./conffiles"))
      String.new(conffiles.content).should eq("/etc/toy/toy.conf\n")
    end
  end

  # A file left behind is not uploaded, but the next run without --clean
  # stops on "dist/ is not empty".
  it "leaves no file behind when a package cannot be written" do
    config = CONFIG.sub("maintainer: Jane Doe <jane@example.com>", %(maintainer: "Jane Doe\\n<jane@example.com>"))
    Fixture.project(config: config) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::FormatError, "control field Maintainer must be a single line") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
      Dir.children(project.path("dist")).should eq(["toy_linux_amd64"])
    end
  end

  it "refuses two packages of the same name instead of overwriting the first" do
    Fixture.project(config: CONFIG + "\n    file_name_template: \"{{ .PackageName }}\"\n") do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      fake_binary(ctx, "linux", "arm64")
      expect_raises(Crystalreleaser::PackageError,
        "nfpms[0]: two artifacts would be named toy.deb; add .Arch to file_name_template") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
    end
  end

  it "refuses a content installed over the binary" do
    Fixture.project(config: CONFIG.sub("/usr/share/doc/toy/LICENSE", "/usr/local/bin/toy")) do |project|
      project.write("LICENSE", "MIT\n")
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::PackageError, "nfpms[0]: /usr/local/bin/toy is installed twice") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
    end
  end

  it "is skipped without linux binaries" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project)
      fake_binary(ctx, "darwin", "arm64")
      Crystalreleaser::Pipes::Nfpm.new.skip?(ctx).should eq("no linux binaries")
    end
  end

  it "fails on a missing content file" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      expect_raises(Crystalreleaser::PackageError, "nfpms[0].contents[0].src: file not found: LICENSE") do
        Crystalreleaser::Pipes::Nfpm.new.run(ctx)
      end
    end
  end
end
