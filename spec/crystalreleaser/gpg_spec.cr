require "../spec_helper"

private FIXTURES   = File.join(__DIR__, "../fixtures/gpg")
private PASSPHRASE = "crystalreleaser-spec"

private def secret_key(name : String) : String
  File.read(File.join(FIXTURES, "#{name}-secret.asc"))
end

# A scratch directory, short enough for the sockets of a gpg home.
private def with_scratch(& : String ->) : Nil
  dir = File.join(Dir.tempdir, "crel-spec-#{Random::Secure.hex(4)}")
  Dir.mkdir(dir, 0o700)
  begin
    yield dir
  ensure
    Process.run("gpgconf", ["--homedir", dir, "--kill", "gpg-agent"], error: Process::Redirect::Close)
    FileUtils.rm_rf(dir)
  end
end

# gpg, knowing only the public half of a test key, judges a signature.
private def verify(name : String, signature : Bytes, data : Bytes) : String
  output = ""
  with_scratch do |dir|
    File.write(File.join(dir, "data"), data)
    File.write(File.join(dir, "data.sig"), signature)
    run_tool(["gpg", "--homedir", dir, "--batch", "--import", File.join(FIXTURES, "#{name}-public.asc")])
    output = run_tool(["gpg", "--homedir", dir, "--batch", "--status-fd", "1", "--verify",
                       File.join(dir, "data.sig"), File.join(dir, "data")])
  end
  output
end

describe Crystalreleaser::Gpg do
  it "signs with an RSA key protected by a passphrase" do
    pending_tool!("gpg")
    data = "the header of a package".to_slice
    signature = Crystalreleaser::Gpg.open(secret_key("rsa"), PASSPHRASE, &.sign(data))
    # Binary, not armored: an OpenPGP packet has its first bit set.
    (signature[0] & 0x80).should eq(0x80)
    Crystalreleaser::Formats::Rpm.signature_tag(signature).should eq(268)
    verify("rsa", signature, data).should contain("VALIDSIG 9BCB5C9D9BCDDC23B63C403FB7A81D331E802F50")
  end

  it "signs with an Ed25519 key without a passphrase" do
    pending_tool!("gpg")
    data = "the header of a package".to_slice
    signature = Crystalreleaser::Gpg.open(secret_key("ed25519"), &.sign(data))
    Crystalreleaser::Formats::Rpm.signature_tag(signature).should eq(267)
    verify("ed25519", signature, data).should contain("VALIDSIG 6CC6E8C79701909AA1CE8A209C8CDABADD46C2D3")
  end

  it "signs several times with one imported key" do
    pending_tool!("gpg")
    Crystalreleaser::Gpg.open(secret_key("ed25519")) do |gpg|
      verify("ed25519", gpg.sign("one".to_slice), "one".to_slice).should contain("VALIDSIG")
      verify("ed25519", gpg.sign("two".to_slice), "two".to_slice).should contain("VALIDSIG")
    end
  end

  # A package signed twice must be the same file: a release run again then
  # finds the assets it already uploaded unchanged. 1794973500 is a minute
  # after the test keys were created.
  it "dates the signature as asked, which makes it reproducible" do
    pending_tool!("gpg")
    data = "the header of a package".to_slice
    time = Time.unix(1_794_973_500)
    {"rsa" => PASSPHRASE, "ed25519" => ""}.each do |name, passphrase|
      first = Crystalreleaser::Gpg.open(secret_key(name), passphrase, &.sign(data, time))
      second = Crystalreleaser::Gpg.open(secret_key(name), passphrase, &.sign(data, time))
      second.should eq(first)
      verify(name, first, data).should match(/VALIDSIG [0-9A-F]{40} 2026-11-18 1794973500 /)
    end
  end

  # gpg refuses to sign before the key exists, and a signature older than
  # its key verifies nowhere: the creation of the key is the earliest date.
  # 1794973418 is when the RSA test key was created.
  it "never dates a signature before the key was created" do
    pending_tool!("gpg")
    data = "the header of a package".to_slice
    signature = Crystalreleaser::Gpg.open(secret_key("rsa"), PASSPHRASE, &.sign(data, Time.utc(2020, 1, 1)))
    verify("rsa", signature, data).should match(/VALIDSIG [0-9A-F]{40} 2026-11-18 1794973418 /)
  end

  # Which one signs, and which public keys are published, would be gpg's
  # choice and not the user's.
  it "refuses key material holding several private keys" do
    pending_tool!("gpg")
    expect_raises(Crystalreleaser::PackageError,
      "the signing key holds 2 private keys: export the one that signs, with gpg --armor --export-secret-keys <key id>") do
      Crystalreleaser::Gpg.open(secret_key("rsa") + secret_key("ed25519"), PASSPHRASE) { }
    end
  end

  it "exports the public half of the key it signs with, armored" do
    pending_tool!("gpg")
    public_key = Crystalreleaser::Gpg.open(secret_key("rsa"), PASSPHRASE, &.public_key)
    public_key.should start_with("-----BEGIN PGP PUBLIC KEY BLOCK-----\n")
    public_key.should_not contain("PRIVATE KEY")
    with_scratch do |dir|
      File.write(File.join(dir, "exported.asc"), public_key)
      run_tool(["gpg", "--homedir", dir, "--batch", "--with-colons", "--show-keys", File.join(dir, "exported.asc")])
        .should contain("fpr:::::::::9BCB5C9D9BCDDC23B63C403FB7A81D331E802F50:")
    end
  end

  it "keeps the key in a private directory, gone once done" do
    pending_tool!("gpg")
    home = ""
    Crystalreleaser::Gpg.open(secret_key("rsa"), PASSPHRASE) do |gpg|
      home = gpg.home
      File.info(home).permissions.value.should eq(0o700)
      gpg.sign("data".to_slice)
      # The exported key is gone as soon as gpg has it, and what remains of
      # the secrets is for the owner alone.
      File.exists?(File.join(home, "key.asc")).should be_false
      File.info(File.join(home, "passphrase")).permissions.value.should eq(0o600)
      stored = Dir.glob(File.join(home, "private-keys-v1.d", "*"))
      stored.should_not be_empty
      stored.each { |path| (File.info(path).permissions.value & 0o077).should eq(0) }
    end
    home.should_not be_empty
    Dir.exists?(home).should be_false
  end

  it "removes its directory when the block fails" do
    pending_tool!("gpg")
    home = ""
    expect_raises(Exception, "boom") do
      Crystalreleaser::Gpg.open(secret_key("ed25519")) do |gpg|
        home = gpg.home
        raise "boom"
      end
    end
    Dir.exists?(home).should be_false
  end

  # Arguments are readable by every process of the machine (ps): the key and
  # the passphrase only ever travel in files.
  it "passes neither the key nor the passphrase as a command argument" do
    pending_tool!("gpg")
    with_scratch do |dir|
      log = File.join(dir, "argv.log")
      wrapper = File.join(dir, "gpg-wrapper")
      File.write(wrapper, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> #{log}\nexec gpg \"$@\"\n", perm: 0o700)
      key = secret_key("rsa")
      Crystalreleaser::Gpg.open(key, PASSPHRASE, command: wrapper) do |gpg|
        gpg.sign("data".to_slice)
        gpg.public_key
      end
      arguments = File.read(log)
      arguments.should contain("--detach-sign")
      arguments.should_not contain(PASSPHRASE)
      key.lines.reject(&.empty?).each { |line| arguments.should_not contain(line) }
    end
  end

  it "says so when the passphrase is wrong, without repeating it" do
    pending_tool!("gpg")
    error = expect_raises(Crystalreleaser::PackageError, "gpg could not sign") do
      Crystalreleaser::Gpg.open(secret_key("rsa"), "not-the-passphrase", &.sign("data".to_slice))
    end
    error.message.to_s.should_not contain("not-the-passphrase")
  end

  it "says so when what it is given is not a private key" do
    pending_tool!("gpg")
    expect_raises(Crystalreleaser::PackageError, "gpg could not import the signing key") do
      Crystalreleaser::Gpg.open("not a key") { }
    end
    public_only = File.read(File.join(FIXTURES, "rsa-public.asc"))
    expect_raises(Crystalreleaser::PackageError, "the signing key holds no private key") do
      Crystalreleaser::Gpg.open(public_only) { }
    end
  end

  it "says so when gpg is not installed" do
    expect_raises(Crystalreleaser::PackageError, "gpg is required to sign packages, and no-such-gpg was not found") do
      Crystalreleaser::Gpg.open(secret_key("ed25519"), command: "no-such-gpg") { }
    end
  end
end
