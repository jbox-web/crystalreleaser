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

# The sample package plus /usr/bin/toy-manager, a symbolic link to toy.
private def with_linked_rpm(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
  begin
    spec = sample_package(dir)
    spec.files << Crystalreleaser::Formats::PackageSpec::File.symlink("/usr/bin/toy-manager", "toy")
    path = File.join(dir, "toy.rpm")
    File.open(path, "w") { |file| Rpm.write(file, spec) }
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def parts(path : String)
  File.open(path) { |file| Rpm.read(file) }
end

# An OpenPGP signature packet cut after its fixed fields: old-format header
# (tag 2, one length byte), then version, signature type, public-key
# algorithm and hash algorithm (RFC 4880, 5.2.3).
private def signature_packet(version : Int, pubkey_algo : Int) : Bytes
  Bytes[0x88, 0x04, version, 0x00, pubkey_algo, 0x08]
end

# The architecture of this machine, which is also the one of its docker
# daemon: rpm refuses to install a package built for another one.
private HOST_ARCH = {% if flag?(:aarch64) %}"arm64"{% else %}"amd64"{% end %}

# A package signed by gpg with the test key `name` (spec/fixtures/gpg), next
# to that key's public half as `key.asc`. Yields the directory holding both.
private def with_signed_rpm(name : String, passphrase : String = "", & : String ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
  begin
    spec = sample_package(dir)
    spec.arch = HOST_ARCH
    spec.dependencies = [] of String
    File.copy(File.join(__DIR__, "../../fixtures/gpg/#{name}-public.asc"), File.join(dir, "key.asc"))
    key = File.read(File.join(__DIR__, "../../fixtures/gpg/#{name}-secret.asc"))
    Crystalreleaser::Gpg.open(key, passphrase) do |gpg|
      File.open(File.join(dir, "toy.rpm"), "w") { |file| Rpm.write(file, spec, ->(data : Bytes) { gpg.sign(data) }) }
    end
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Crystalreleaser::Formats::Rpm do
  # A package without symbolic link is the one the release before aliases
  # wrote. The digest comes from release 0.3.0 (commit 6c86ed4, 2026-11-18):
  # its own Rpm.write, run on this same sample_package.
  it "writes, without symbolic link, the bytes release 0.3.0 wrote" do
    with_rpm do |path|
      Digest::SHA256.hexdigest(File.read(path)).should eq("ab6ebfc43d8155a719b29ccc9ab24dc73119fe2c4dbb412363df4f4357c628ea")
    end
  end

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

  it "carries no OpenPGP signature when none is asked for" do
    with_rpm do |path|
      signature = parts(path)[1]
      signature.has_key?(Tag::SIG_RSA).should be_false
      signature.has_key?(Tag::SIG_DSA).should be_false
    end
  end

  # rpm reads a header-only signature from RSAHEADER (268) when the key is
  # RSA, and from DSAHEADER (267) for DSA, ECDSA and EdDSA.
  {
    {1, 268, "RSA"},
    {17, 267, "DSA"},
    {19, 267, "ECDSA"},
    {22, 267, "EdDSA"},
  }.each do |(algo, tag, label)|
    it "stores the #{label} signature of the main header, magic included, under tag #{tag}" do
      dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
      begin
        spec = sample_package(dir)
        signed = Bytes.empty
        packet = signature_packet(4, algo)
        io = IO::Memory.new
        Rpm.write(io, spec, ->(data : Bytes) { signed = data.dup; packet })

        _, signature, _, header, _ = Rpm.read(IO::Memory.new(io.to_slice))
        signature[tag].should eq(packet)
        signed.should eq(header)
        signed[0, 8].should eq(Bytes[0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0])
        # The digests of an unsigned package are still there.
        signature[Tag::SIG_SHA256].should eq(Digest::SHA256.hexdigest(header))
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "reads the algorithm of a signature packet with a new-format header" do
    Rpm.signature_tag(Bytes[0xc2, 0x04, 0x04, 0x00, 0x16, 0x0a]).should eq(267)
    Rpm.signature_tag(Bytes[0xc2, 0x04, 0x04, 0x00, 0x01, 0x08]).should eq(268)
  end

  it "refuses a signature rpm has no header tag for" do
    expect_raises(Crystalreleaser::FormatError, "an RPM package cannot hold an OpenPGP v6 signature (v4 only)") do
      Rpm.signature_tag(signature_packet(6, 1))
    end
    expect_raises(Crystalreleaser::FormatError, "an RPM package cannot hold a signature of OpenPGP public-key algorithm 16") do
      Rpm.signature_tag(signature_packet(4, 16))
    end
    expect_raises(Crystalreleaser::FormatError, "not an OpenPGP signature packet") do
      Rpm.signature_tag(Bytes[0x99, 0x04, 0x04, 0x00, 0x01, 0x08])
    end
    expect_raises(Crystalreleaser::FormatError, "not an OpenPGP signature packet") do
      Rpm.signature_tag(Bytes[0x88])
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

  # The values of a package rpmbuild wrote in rockylinux:9 for a link to
  # `tool`: mode=120777 size=4 linkto=tool digest= (empty). Here the link
  # points at `toy`, three bytes.
  it "describes a symbolic link as rpmbuild does: mode 0120777, its target, the target's length, no digest" do
    with_linked_rpm do |path|
      header = parts(path)[2]
      header[Tag::BASENAMES].should eq(["toy", "toy-manager", "toy", "LICENSE"])
      header[Tag::FILEMODES].should eq([0o100755.to_i16!, 0o120777.to_i16!, 0o040755.to_i16!, 0o100644.to_i16!])
      header[Tag::FILELINKTOS].should eq(["", "toy", "", ""])
      header[Tag::FILESIZES].should eq([19, 3, 0, 4])
      header[Tag::FILEDIGESTS].should eq([
        "e2f4e996519178770f794b78aba73fddac826493dc40d36d10690bc66e4f7216",
        "",
        "",
        "adc37366f403835c1470ab2df93d3837d4719372fc1ef8593d922e06f033f8b2",
      ])
    end
  end

  # rpmbuild counts a link in SIZE by the length of its target: a 10-byte
  # file and a link to `tool` gave SIZE 14 (rockylinux:9, 2026-11-18). Here
  # 19 + 4 bytes of files and a link to `toy`, 3 bytes.
  it "counts the length of a symbolic link's target in the package size, as rpmbuild does" do
    with_linked_rpm do |path|
      parts(path)[2][Tag::SIZE].should eq([26])
    end
  end

  it "carries the symbolic link in the payload with its target as data" do
    with_linked_rpm do |path|
      payload = parts(path)[4]
      entries = Compress::Gzip::Reader.open(IO::Memory.new(payload)) { |gzip| Crystalreleaser::Formats::Cpio.read(gzip) }
      link = entries.find!(&.name.==("./usr/bin/toy-manager"))
      {link.mode, String.new(link.content)}.should eq({0o120777, "toy"})
    end
  end

  # --dump: path size mtime digest mode owner group isconfig isdoc rdev symlink.
  it "has its symbolic link dumped by rpm" do
    pending_tool!("rpm")
    with_linked_rpm do |path|
      fields = run_tool(["rpm", "-qp", "--dump", path]).lines.find!(&.starts_with?("/usr/bin/toy-manager ")).split(' ')
      {fields[0], fields[1], fields[4], fields.last}.should eq({"/usr/bin/toy-manager", "3", "0120777", "toy"})
      run_tool(["rpm", "-K", "--nosignature", path]).should contain("digests OK")
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

  # gpg signs and rpm judges: an RSA key protected by a passphrase, and an
  # Ed25519 key without one.
  {
    {"rsa", "crystalreleaser-spec"},
    {"ed25519", ""},
  }.each do |(name, passphrase)|
    it "has its #{name} signature verified by rpm once the public key is imported" do
      pending_tool!("gpg")
      pending_tool!("rpm")
      with_signed_rpm(name, passphrase) do |dir|
        db = File.join(dir, "rpmdb")
        run_tool(["rpm", "--dbpath", db, "--import", File.join(dir, "key.asc")])
        run_tool(["rpm", "--dbpath", db, "-K", File.join(dir, "toy.rpm")]).should contain("digests signatures OK")
      end
    end

    # Fedora's rpm 6 refuses an unsigned package: this is the install the
    # signature is for. Rocky Linux 9 has the rpm 4.16 of RHEL 9, which reads
    # the same header tags.
    {"fedora:latest", "rockylinux:9"}.each do |image|
      it "installs on #{image} without --nosignature when signed with the #{name} key", tags: "docker" do
        pending_tool!("gpg")
        with_signed_rpm(name, passphrase) do |dir|
          output = run_tool(["docker", "run", "--rm", "--platform", "linux/#{HOST_ARCH}", "-v", "#{dir}:/pkg:ro", image, "sh", "-ec",
                             "rpm --import /pkg/key.asc; rpm -K /pkg/toy.rpm; rpm -i /pkg/toy.rpm; /usr/bin/toy"])
          output.should contain("/pkg/toy.rpm: digests signatures OK")
          output.lines.last.should eq("toy")
        end
      end
    end
  end

  it "is refused by Fedora's rpm when it is not signed", tags: "docker" do
    dir = File.join(Dir.tempdir, "crystalreleaser-rpm-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      spec.arch = HOST_ARCH
      spec.dependencies = [] of String
      File.open(File.join(dir, "toy.rpm"), "w") { |file| Rpm.write(file, spec) }
      status, output = Crystalreleaser::Subprocess.run("docker",
        ["run", "--rm", "--platform", "linux/#{HOST_ARCH}", "-v", "#{dir}:/pkg:ro", "fedora:latest", "rpm", "-i", "/pkg/toy.rpm"])
      status.success?.should be_false
      output.should contain("does not verify: no signature")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
