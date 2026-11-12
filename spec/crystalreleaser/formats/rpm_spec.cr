require "../../spec_helper"

private alias Rpm = Crystalreleaser::Formats::Rpm
private alias Tag = Crystalreleaser::Formats::Rpm::Tag

private def with_rpm(& : String, Crystalreleaser::Formats::PackageSpec ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
  begin
    spec = sample_package(dir)
    path = File.join(dir, "toy.rpm")
    File.open(path, "w") { |file| Rpm.write(file, spec) }
    yield path, spec
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def parts(path : String)
  File.open(path) { |file| Rpm.read(file) }
end

describe Crystalreleaser::Formats::Rpm do
  it "starts with a 96-byte v3 lead naming the package" do
    with_rpm do |path|
      lead = parts(path)[0]
      lead[0, 4].should eq(Bytes[0xed, 0xab, 0xee, 0xdb])
      {lead[4], lead[5]}.should eq({3_u8, 0_u8})
      String.new(lead[10, 66]).rstrip('\0').should eq("toy-1.2.3~rc.1-1")
    end
  end

  it "signs the header with its SHA256 and header + payload with MD5 and size" do
    with_rpm do |path|
      _, signature, _, header, payload = parts(path)
      signature[Tag::SIG_SHA256].should eq(Digest::SHA256.hexdigest(header))
      signature[Tag::SIG_SHA1].should eq(Digest::SHA1.hexdigest(header))
      signature[Tag::SIG_SIZE].should eq([header.size + payload.size])
      md5 = Digest::MD5.new
      md5.update(header)
      md5.update(payload)
      signature[Tag::SIG_MD5].should eq(md5.final)
    end
  end

  it "carries the SHA256 of the payload, compressed and uncompressed, as current rpm requires" do
    with_rpm do |path|
      _, _, header, _, payload = parts(path)
      uncompressed = Compress::Gzip::Reader.open(IO::Memory.new(payload), &.getb_to_end)
      header[Tag::PAYLOADDIGESTALGO].should eq([8])
      header[Tag::PAYLOADDIGEST].should eq([Digest::SHA256.hexdigest(payload)])
      header[Tag::PAYLOADDIGESTALT].should eq([Digest::SHA256.hexdigest(uncompressed)])
    end
  end

  it "describes the package and its files" do
    with_rpm do |path|
      header = parts(path)[2]
      {header[Tag::NAME], header[Tag::VERSION], header[Tag::RELEASE], header[Tag::ARCH], header[Tag::OS]}
        .should eq({"toy", "1.2.3~rc.1", "1", "x86_64", "linux"})
      header[Tag::SUMMARY].should eq(["A toy"])
      header[Tag::LICENSE].should eq("MIT")
      header[Tag::URL].should eq("https://example.com/toy")
      header[Tag::PAYLOADFORMAT].should eq("cpio")
      header[Tag::PAYLOADCOMPRESSOR].should eq("gzip")
      # /usr/share/doc/toy is the package's own directory: it is listed, so
      # that removing the package removes it. /usr/bin belongs to the system.
      header[Tag::BASENAMES].should eq(["toy", "toy", "LICENSE"])
      header[Tag::DIRNAMES].should eq(["/usr/bin/", "/usr/share/doc/", "/usr/share/doc/toy/"])
      header[Tag::DIRINDEXES].should eq([0, 1, 2])
      header[Tag::FILEMODES].should eq([0o100755.to_i16!, 0o040755.to_i16!, 0o100644.to_i16!])
      header[Tag::FILESIZES].should eq([19, 0, 4])
      header[Tag::FILEUSERNAME].should eq(["root", "root", "root"])
      # sha256sum of "#!/bin/sh\necho toy\n" and of "MIT\n"; none for a directory.
      header[Tag::FILEDIGESTS].should eq([
        "e2f4e996519178770f794b78aba73fddac826493dc40d36d10690bc66e4f7216",
        "",
        "adc37366f403835c1470ab2df93d3837d4719372fc1ef8593d922e06f033f8b2",
      ])
    end
  end

  it "requires the rpmlib features it uses plus the declared dependencies" do
    with_rpm do |path|
      header = parts(path)[2]
      header[Tag::REQUIRENAME].should eq([
        "rpmlib(CompressedFileNames)", "rpmlib(FileDigests)", "rpmlib(PayloadFilesHavePrefix)",
        "libc6", "ca-certificates",
      ])
      header[Tag::REQUIREVERSION].should eq(["3.0.4-1", "4.6.0-1", "4.0-1", "", ""])
      header[Tag::REQUIREFLAGS].should eq([16777226, 16777226, 16777226, 0, 0])
    end
  end

  it "carries a gzipped cpio payload with ./ paths" do
    with_rpm do |path|
      payload = parts(path)[4]
      entries = Compress::Gzip::Reader.open(IO::Memory.new(payload)) { |gzip| Crystalreleaser::Formats::Cpio.read(gzip) }
      entries.map { |entry| {entry.name, entry.mode} }
        .should eq([{"./usr/bin/toy", 0o100755}, {"./usr/share/doc/toy", 0o040755}, {"./usr/share/doc/toy/LICENSE", 0o100644}])
    end
  end

  it "parses dependency constraints" do
    Rpm.parse_dependency("glibc").should eq({"glibc", "", 0})
    Rpm.parse_dependency("glibc >= 2.31").should eq({"glibc", "2.31", 12})
    Rpm.parse_dependency("foo < 2").should eq({"foo", "2", 2})
    Rpm.parse_dependency("foo>=1.0").should eq({"foo", "1.0", 12})
    Rpm.parse_dependency("foo (>> 3)").should eq({"foo", "3", 4})
    Rpm.parse_dependency("foo = 1.2-3").should eq({"foo", "1.2-3", 8})
  end

  # The times of an RPM header are signed 32-bit seconds.
  it "refuses a time after 2038 with a message, not an overflow" do
    with_rpm do |_, spec|
      spec.mtime = Time.utc(2040, 1, 1)
      expect_raises(Crystalreleaser::FormatError, "an RPM package cannot hold a date after 2038-01-19") do
        Rpm.write(IO::Memory.new, spec)
      end
    end
  end

  it "names the file that does not fit the 32-bit sizes of an RPM header" do
    expect_raises(Crystalreleaser::FormatError, "/usr/bin/toy is too large for an RPM package (2 GiB limit)") do
      Rpm.int32(3_i64 * 1024 * 1024 * 1024, "/usr/bin/toy")
    end
    Rpm.int32(19_i64, "/usr/bin/toy").should eq(19)
  end

  it "flags no file as configuration by default" do
    with_rpm do |path|
      parts(path)[2][Tag::FILEFLAGS].should eq([0, 0, 0])
    end
  end

  # rpm's file flags: RPMFILE_CONFIG is 1, RPMFILE_NOREPLACE is 16. A config
  # file changed on disk is saved as .rpmsave on upgrade; with noreplace it
  # is kept and the new one lands as .rpmnew.
  it "flags the configuration files, and the ones never to replace" do
    dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      File.write(File.join(dir, "toy.conf"), "verbose = no\n")
      File.write(File.join(dir, "extra.conf"), "x = 1\n")
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/toy.conf", File.join(dir, "toy.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::ConfigNoreplace)
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/extra.conf", File.join(dir, "extra.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::Config)
      path = File.join(dir, "toy.rpm")
      File.open(path, "w") { |file| Rpm.write(file, spec) }

      header = parts(path)[2]
      # Sorted by path: /etc/toy, /etc/toy/extra.conf, /etc/toy/toy.conf, /usr/bin/toy, ...
      header[Tag::BASENAMES].should eq(["toy", "extra.conf", "toy.conf", "toy", "toy", "LICENSE"])
      header[Tag::FILEFLAGS].should eq([0, 1, 17, 0, 0, 0])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "has its configuration files listed by rpm" do
    pending_tool!("rpm")
    dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      File.write(File.join(dir, "toy.conf"), "verbose = no\n")
      spec.files << Crystalreleaser::Formats::PackageSpec::File.new("/etc/toy/toy.conf", File.join(dir, "toy.conf"), 0o644,
        Crystalreleaser::Formats::PackageSpec::Kind::Config)
      path = File.join(dir, "toy.rpm")
      File.open(path, "w") { |file| Rpm.write(file, spec) }
      run_tool(["rpm", "-qcp", path]).lines.should eq(["/etc/toy/toy.conf"])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "is accepted by rpm" do
    pending_tool!("rpm")
    with_rpm do |path|
      info = run_tool(["rpm", "-qip", path])
      info.should match(/^Name\s*: toy$/m)
      info.should match(/^Version\s*: 1\.2\.3~rc\.1$/m)
      run_tool(["rpm", "-qlp", path]).lines.should eq(["/usr/bin/toy", "/usr/share/doc/toy", "/usr/share/doc/toy/LICENSE"])
      run_tool(["rpm", "-K", "--nosignature", path]).should contain("digests OK")
    end
  end
end
