require "../spec_helper"

# The expected values are written out per compile flag here, independently
# of host.cr, so a wrong mapping there cannot agree with itself.
private EXPECTED_OS = {% if flag?(:linux) %}
                        "linux"
                      {% elsif flag?(:darwin) %}
                        "darwin"
                      {% elsif flag?(:freebsd) %}
                        "freebsd"
                      {% else %}
                        nil
                      {% end %}

private EXPECTED_ARCH = {% if flag?(:x86_64) %}
                          "amd64"
                        {% elsif flag?(:aarch64) %}
                          "arm64"
                        {% else %}
                          nil
                        {% end %}

describe Crystalreleaser::Host do
  describe ".current_os" do
    it "is the os the binary was compiled for, in the config vocabulary" do
      expected = EXPECTED_OS || pending!("no expectation written for this os")
      Crystalreleaser::Host.current_os.should eq(expected)
    end
  end

  describe ".current_arch" do
    it "is the architecture the binary was compiled for, in the config vocabulary" do
      expected = EXPECTED_ARCH || pending!("no expectation written for this architecture")
      Crystalreleaser::Host.current_arch.should eq(expected)
    end
  end

  describe ".current" do
    it "combines the current os and arch" do
      host = Crystalreleaser::Host.current
      {host.os, host.arch}.should eq({EXPECTED_OS, EXPECTED_ARCH})
    end

    # Judged by something host.cr does not read: the libc a native build
    # links is the one of the distribution, and Alpine is the musl one.
    it "says musl on Alpine only, whatever libc this binary was compiled against" do
      Crystalreleaser::Host.current.musl?.should eq(File.exists?("/etc/alpine-release"))
    end
  end

  # What matters is the libc `crystal build` links on this machine, which the
  # compiler names in its default target: not the libc of crystalreleaser
  # itself, whose released Linux binary is a static musl one that runs on
  # glibc hosts too.
  describe ".musl_toolchain?" do
    it "is true when the compiler targets musl" do
      Crystalreleaser::Host.musl_toolchain?(<<-TEXT).should be_true
        Crystal 1.20.3 [1c0bd1c4f] (2026-06-02)

        LLVM: 20.1.8
        Default target: x86_64-alpine-linux-musl
        TEXT
      Crystalreleaser::Host.musl_toolchain?("Default target: aarch64-unknown-linux-musl\n").should be_true
    end

    it "is false when the compiler targets glibc" do
      Crystalreleaser::Host.musl_toolchain?(<<-TEXT).should be_false
        Crystal 1.20.3 [1c0bd1c4f] (2026-06-02)

        LLVM: 18.1.8
        Default target: x86_64-unknown-linux-gnu
        TEXT
    end

    it "is false without a compiler, or when the word is not the target" do
      Crystalreleaser::Host.musl_toolchain?("").should be_false
      Crystalreleaser::Host.musl_toolchain?("Crystal 1.20.3 [musl] (2026-06-02)\nDefault target: aarch64-apple-darwin\n").should be_false
    end
  end

  describe "#matches?" do
    it "compares os and arch" do
      host = Crystalreleaser::Host.new("linux", "arm64", musl: true)
      host.matches?("linux", "arm64").should be_true
      host.matches?("linux", "amd64").should be_false
      host.to_s.should eq("linux/arm64")
    end
  end
end
