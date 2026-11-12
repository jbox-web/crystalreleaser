require "../../spec_helper"

private def with_deb(& : String, Crystalreleaser::Formats::PackageSpec ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-deb-#{Random::Secure.hex(6)}")
  begin
    spec = sample_package(dir)
    path = File.join(dir, "toy.deb")
    File.open(path, "w") { |file| Crystalreleaser::Formats::Deb.write(file, spec) }
    yield path, spec
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def members(path : String) : Array(Crystalreleaser::Formats::Ar::Member)
  File.open(path) { |file| Crystalreleaser::Formats::Ar.read(file) }
end

private def untar(bytes : Bytes) : Array(Crystalreleaser::Formats::Tar::Entry)
  Compress::Gzip::Reader.open(IO::Memory.new(bytes)) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
end

describe Crystalreleaser::Formats::Deb do
  it "holds debian-binary, control.tar.gz and data.tar.gz, in that order" do
    with_deb do |path|
      list = members(path)
      list.map(&.name).should eq(["debian-binary", "control.tar.gz", "data.tar.gz"])
      String.new(list.first.content).should eq("2.0\n")
    end
  end

  it "writes the control file" do
    with_deb do |path|
      control = untar(members(path)[1].content).find!(&.name.==("./control"))
      String.new(control.content).should eq(<<-CONTROL)
        Package: toy
        Version: 1.2.3~rc.1
        Section: utils
        Priority: optional
        Architecture: amd64
        Maintainer: Jane Doe <jane@example.com>
        Installed-Size: 1
        Depends: libc6, ca-certificates
        Homepage: https://example.com/toy
        Description: A toy
         It prints its name.
         .
         That is all.

        CONTROL
    end
  end

  # A snapshot version has two hyphens (1.2.4-SNAPSHOT-abc1234), and neither
  # format takes one in its version.
  it "leaves no hyphen in the version, however many the semver one has" do
    spec = Crystalreleaser::Formats::PackageSpec.new("toy", "1.2.4-SNAPSHOT-abc1234", "amd64")
    spec.package_version.should eq("1.2.4~SNAPSHOT~abc1234")
    Crystalreleaser::Formats::PackageSpec.new("toy", "1.2.3", "amd64").package_version.should eq("1.2.3")
  end

  it "writes versioned dependencies in Debian syntax, whichever syntax the config used" do
    with_deb do |_, spec|
      spec.dependencies = ["libfoo >= 1.0", "bar<2", "baz (>> 3)", "qux = 1.2-3", "plain"]
      Crystalreleaser::Formats::Deb.control(spec)
        .should contain("Depends: libfoo (>= 1.0), bar (<< 2), baz (>> 3), qux (= 1.2-3), plain\n")
    end
  end

  it "keeps the first line of a description that starts with a blank line" do
    with_deb do |_, spec|
      spec.description = "\nFirst line\nSecond line\n"
      Crystalreleaser::Formats::Deb.control(spec).should contain("Description: First line\n Second line\n")
    end
  end

  it "refuses a line break in a single-line field, which would add a field" do
    with_deb do |_, spec|
      spec.homepage = "https://x\nPre-Depends: evil"
      expect_raises(Crystalreleaser::FormatError, "control field Homepage must be a single line") do
        Crystalreleaser::Formats::Deb.control(spec)
      end
    end
  end

  it "lists the md5 of every file" do
    with_deb do |path|
      md5sums = untar(members(path)[1].content).find!(&.name.==("./md5sums"))
      # md5sum of "#!/bin/sh\necho toy\n" and of "MIT\n", from the md5sum tool.
      String.new(md5sums.content).should eq(
        "5d03ed0711b2626a4c3dfb5dbe151c9d  usr/bin/toy\n" \
        "477dfa54ede28e2f361e7db05941d7a7  usr/share/doc/toy/LICENSE\n")
    end
  end

  it "has no conffiles member without a configuration file" do
    with_deb do |path|
      untar(members(path)[1].content).map(&.name).should eq(["./", "./control", "./md5sums"])
    end
  end

  # Debian policy: conffiles lists, one absolute path per line, the files
  # dpkg must not overwrite once the administrator has changed them.
  it "lists the configuration files in conffiles, whether noreplace or not" do
    dir = File.join(Dir.tempdir, "crystalreleaser-deb-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      File.write(File.join(dir, "toy.conf"), "verbose = no\n")
      File.write(File.join(dir, "extra.conf"), "x = 1\n")
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/toy.conf", File.join(dir, "toy.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::ConfigNoreplace)
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/extra.conf", File.join(dir, "extra.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::Config)
      path = File.join(dir, "toy.deb")
      File.open(path, "w") { |file| Crystalreleaser::Formats::Deb.write(file, spec) }

      control = untar(members(path)[1].content)
      control.map(&.name).should eq(["./", "./control", "./md5sums", "./conffiles"])
      String.new(control.last.content).should eq("/etc/toy/extra.conf\n/etc/toy/toy.conf\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "has its configuration files read by dpkg-deb" do
    pending_tool!("dpkg-deb")
    dir = File.join(Dir.tempdir, "crystalreleaser-deb-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      File.write(File.join(dir, "toy.conf"), "verbose = no\n")
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/toy.conf", File.join(dir, "toy.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::Config)
      path = File.join(dir, "toy.deb")
      File.open(path, "w") { |file| Crystalreleaser::Formats::Deb.write(file, spec) }
      run_tool(["dpkg-deb", "--info", path, "conffiles"]).should eq("/etc/toy/toy.conf\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "lists every parent directory explicitly, with ./ paths and root ownership" do
    with_deb do |path|
      entries = untar(members(path)[2].content)
      entries.map { |entry| {entry.name, entry.mode, entry.uname} }.should eq([
        {"./", 0o755, "root"},
        {"./usr/", 0o755, "root"},
        {"./usr/bin/", 0o755, "root"},
        {"./usr/share/", 0o755, "root"},
        {"./usr/share/doc/", 0o755, "root"},
        {"./usr/share/doc/toy/", 0o755, "root"},
        {"./usr/bin/toy", 0o755, "root"},
        {"./usr/share/doc/toy/LICENSE", 0o644, "root"},
      ])
    end
  end

  it "is accepted by dpkg-deb" do
    pending_tool!("dpkg-deb")
    with_deb do |path|
      info = run_tool(["dpkg-deb", "--info", path])
      info.should contain(" Package: toy\n")
      info.should contain(" Version: 1.2.3~rc.1\n")
      contents = run_tool(["dpkg-deb", "--contents", path])
      contents.should contain("./usr/bin/toy")
      contents.lines.find!(&.ends_with?("./usr/bin/toy")).should start_with("-rwxr-xr-x root/root")
    end
  end
end
