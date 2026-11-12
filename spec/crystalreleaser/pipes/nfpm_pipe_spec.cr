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

describe Crystalreleaser::Pipes::Nfpm do
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
