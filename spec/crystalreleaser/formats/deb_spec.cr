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

# The sample package plus /usr/bin/toy-manager, a symbolic link to toy.
private def with_linked_deb(& : String, String ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-deb-#{Random::Secure.hex(6)}")
  begin
    spec = sample_package(dir)
    spec.files << Crystalreleaser::Formats::PackageSpec::File.symlink("/usr/bin/toy-manager", "toy")
    path = File.join(dir, "toy.deb")
    File.open(path, "w") { |file| Crystalreleaser::Formats::Deb.write(file, spec) }
    yield path, dir
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
  # A package without symbolic link is the one the release before aliases
  # wrote. The digest comes from release 0.3.0 (commit 6c86ed4, 2026-11-18):
  # its own Deb.write, run on this same sample_package.
  it "writes, without symbolic link, the bytes release 0.3.0 wrote" do
    with_deb do |path|
      Digest::SHA256.hexdigest(File.read(path)).should eq("54b5f21a6a4080c20a5f477742293d3b94934db8c61edf5e36527786fa5cadf9")
    end
  end

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

  # ustar: typeflag at 156, linkname at 157, size at 124, mode at 100 of the
  # header block, read from the bytes data.tar.gz holds.
  it "puts a symbolic link in data.tar.gz, its target relative, in the same directory" do
    with_linked_deb do |path, dir|
      data = File.join(dir, "data.tar.gz")
      File.write(data, members(path)[2].content)
      header = tar_header(data, "./usr/bin/toy-manager")
      header[156].chr.should eq('2')
      String.new(header[157, 3]).should eq("toy")
      header[160, 97].all?(&.zero?).should be_true
      String.new(header[124, 12]).should eq("00000000000\0")
      String.new(header[100, 8]).should eq("0000777\0")
      untar(members(path)[2].content).map(&.name).should eq([
        "./", "./usr/", "./usr/bin/", "./usr/share/", "./usr/share/doc/", "./usr/share/doc/toy/",
        "./usr/bin/toy", "./usr/bin/toy-manager", "./usr/share/doc/toy/LICENSE",
      ])
    end
  end

  # md5sums lists the content of regular files; a link has none, and dpkg
  # checks it against its target.
  it "gives the symbolic link no md5sums line" do
    with_linked_deb do |path|
      control = untar(members(path)[1].content)
      String.new(control.find!(&.name.==("./md5sums")).content).should eq(
        "5d03ed0711b2626a4c3dfb5dbe151c9d  usr/bin/toy\n" \
        "477dfa54ede28e2f361e7db05941d7a7  usr/share/doc/toy/LICENSE\n")
    end
  end

  # Installed-Size is the KiB the regular files take, rounded up. The two
  # files total exactly 1024 bytes: 1 KiB. A link adds nothing; counted,
  # even for the 3 bytes of its target, it would make 2.
  it "gives the symbolic link no Installed-Size" do
    dir = File.join(Dir.tempdir, "crystalreleaser-deb-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      File.write(File.join(dir, "toy"), "x" * 1000)
      File.write(File.join(dir, "LICENSE"), "y" * 24)
      spec.files << Crystalreleaser::Formats::PackageSpec::File.symlink("/usr/bin/toy-manager", "toy")
      path = File.join(dir, "toy.deb")
      File.open(path, "w") { |file| Crystalreleaser::Formats::Deb.write(file, spec) }
      control = untar(members(path)[1].content)
      String.new(control.find!(&.name.==("./control")).content).should contain("Installed-Size: 1\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "has its symbolic link listed by dpkg-deb" do
    pending_tool!("dpkg-deb")
    with_linked_deb do |path|
      line = run_tool(["dpkg-deb", "--contents", path]).lines.find!(&.includes?("./usr/bin/toy-manager"))
      line.should start_with("lrwxrwxrwx root/root")
      line.should end_with("./usr/bin/toy-manager -> toy")
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
