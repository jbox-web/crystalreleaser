require "../../spec_helper"

describe Crystalreleaser::Builders do
  describe ".triple" do
    it "maps every supported platform to its LLVM triple" do
      {
        {"linux", "amd64", true}   => "x86_64-linux-musl",
        {"linux", "amd64", false}  => "x86_64-linux-gnu",
        {"linux", "arm64", true}   => "aarch64-linux-musl",
        {"linux", "arm64", false}  => "aarch64-linux-gnu",
        {"darwin", "amd64", false} => "x86_64-apple-darwin",
        {"darwin", "arm64", false} => "aarch64-apple-darwin",
        {"freebsd", "amd64", true} => "x86_64-portbld-freebsd",
      }.each do |(os, arch, static), triple|
        Crystalreleaser::Builders.triple(os, arch, static).should eq(triple)
      end
    end

    it "rejects an unknown platform" do
      expect_raises(Crystalreleaser::BuildError, "no target triple for plan9/amd64") do
        Crystalreleaser::Builders.triple("plan9", "amd64", false)
      end
    end
  end

  describe ".file_warnings" do
    it "accepts a static linux amd64 ELF" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped",
        "linux", "amd64", static: true).should be_empty
    end

    it "accepts a static-pie linux arm64 ELF" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), static-pie linked, stripped",
        "linux", "arm64", static: true).should be_empty
    end

    it "accepts Mach-O binaries of both architectures" do
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable arm64", "darwin", "arm64", static: false).should be_empty
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable x86_64", "darwin", "amd64", static: false).should be_empty
    end

    it "warns about a wrong architecture" do
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable x86_64", "darwin", "arm64", static: false)
        .should eq(["expected an arm64 binary, `file` reports: Mach-O 64-bit executable x86_64"])
    end

    it "warns about a dynamic binary where a static one was asked" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-musl-x86_64.so.1",
        "linux", "amd64", static: true)
        .should eq(["expected a statically linked binary, `file` reports: ELF 64-bit LSB pie executable, x86-64, " \
                    "version 1 (SYSV), dynamically linked, interpreter /lib/ld-musl-x86_64.so.1"])
    end
  end

  describe ".capture" do
    # `seq 1 200000` prints 1 288 895 bytes: 9 numbers of 1 digit, 90 of 2,
    # 900 of 3, 9 000 of 4, 90 000 of 5 and 100 001 of 6, one newline each.
    it "returns every byte of a command that floods stdout and stderr at once" do
      done = Channel({Bool, String}).new(1)
      spawn { done.send(Crystalreleaser::Builders.capture(["sh", "-c", "seq 1 200000 & seq 1 200000 >&2; wait"])) }
      select
      when result = done.receive
        result[0].should be_true
        result[1].bytesize.should eq(2_577_790)
        result[1].count('\n').should eq(400_000)
      when timeout(60.seconds)
        fail "the command was still being read after 60 seconds"
      end
    end

    it "reports a missing command" do
      Crystalreleaser::Builders.capture(["crystalreleaser-no-such-command"])
        .should eq({false, "crystalreleaser-no-such-command: command not found"})
    end
  end
end
