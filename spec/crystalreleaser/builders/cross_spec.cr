require "../../spec_helper"

private CONFIG = <<-YAML
  builds:
    - id: toy
      target: toy
      flags: [--release]
      platforms:
        - os: linux
          arch: arm64
          strategy: cross
          static: true
      cross:
        linker: zig
        sysroot: /opt/sysroots/{{ .Os }}-{{ .Arch }}
        link_flags: [-s]
  YAML

describe Crystalreleaser::Builders::Cross do
  it "compiles an object file for the target triple" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      Crystalreleaser::Builders::Cross.new(ctx.host).compile_command(build, build.platforms.first, ctx).should eq([
        "crystal", "build", "src/toy.cr", "--cross-compile", "--target", "aarch64-linux-musl",
        "-o", File.join(project.dir, "dist", "toy_linux_arm64", "toy"), "--release", "--static",
      ])
    end
  end

  it "extracts the libraries of the link command crystal prints" do
    output = <<-TEXT
      Using compiled compiler at .build/crystal
      cc '/tmp/out/toy.o' -o '/tmp/out/toy'  -rdynamic -static -L/usr/local/lib -lpcre2-8 -lgc -lpthread -ldl -L/opt/x
      TEXT
    Crystalreleaser::Builders::Cross.link_flags(output).should eq(["-L/usr/local/lib", "-lpcre2-8", "-lgc", "-lpthread", "-ldl", "-L/opt/x"])
  end

  # The line Crystal 1.20.3 prints on macOS for a program that requires
  # OpenSSL: a library found through pkg-config comes as a shell command
  # substitution, with what to link when pkg-config is missing. That fallback
  # is the only part that does not describe the build machine.
  it "takes the fallback of the libraries crystal looks up with pkg-config" do
    output = "cc xd120.o -o xd120  -rdynamic -L/opt/crystal/embedded/lib -lz " \
             "`command -v pkg-config > /dev/null && pkg-config --libs --silence-errors libssl || printf %s '-lssl -lcrypto'` " \
             "`command -v pkg-config > /dev/null && pkg-config --libs --silence-errors libcrypto || printf %s '-lcrypto'` " \
             "-L/opt/homebrew/Cellar/bdw-gc/8.2.12/lib -lgc -liconv\n"
    Crystalreleaser::Builders::Cross.link_flags(output).should eq([
      "-L/opt/crystal/embedded/lib", "-lz", "-lssl", "-lcrypto", "-L/opt/homebrew/Cellar/bdw-gc/8.2.12/lib", "-lgc", "-liconv",
    ])
  end

  it "refuses a command substitution it cannot read rather than passing pieces of it to the linker" do
    expect_raises(Crystalreleaser::BuildError, "cannot read the libraries of `llvm-config --libs` in the link command") do
      Crystalreleaser::Builders::Cross.link_flags("cc toy.o -o toy -lgc `llvm-config --libs`\n")
    end
  end

  it "fails when the compiler printed no link command, instead of linking without any library" do
    expect_raises(Crystalreleaser::BuildError, "no link command in the output of crystal build --cross-compile:\nUsing compiled compiler") do
      Crystalreleaser::Builders::Cross.link_flags("Using compiled compiler\n")
    end
  end

  # zig prefixes even absolute -L paths with --sysroot (observed with zig
  # 0.17.1: "unable to open library directory <sysroot><sysroot>/lib"), so
  # with zig the sysroot is only given through absolute -L paths. And unlike
  # gcc, which adds libgcc_eh implicitly, zig cc needs -lunwind for the
  # _Unwind_* symbols of Crystal's exception handling on linux.
  it "links with zig against the sysroot's library folders, with libunwind, the libraries and the extra flags" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      out = File.join(project.dir, "dist", "toy_linux_arm64", "toy")
      Crystalreleaser::Builders::Cross.new(ctx.host)
        .link_command(build, build.platforms.first, ctx, ["-L/usr/local/lib", "-lgc", "-lpcre2-8"]).should eq([
        "zig", "cc", "-target", "aarch64-linux-musl",
        "#{out}.o", "-o", out, "-static",
        "-L/opt/sysroots/linux-arm64/lib", "-L/opt/sysroots/linux-arm64/usr/lib", "-L/opt/sysroots/linux-arm64/usr/local/lib",
        "-lgc", "-lpcre2-8", "-lunwind", "-s",
      ])
    end
  end

  it "links with cc and an explicit target when cc is clang" do
    Fixture.project(config: CONFIG.sub("linker: zig", "linker: cc")) do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      Crystalreleaser::Builders::Cross.new(ctx.host)
        .link_command(build, build.platforms.first, ctx, [] of String, cc_version: "Apple clang version 17.0.0 (clang-1700.6.3.2)\n")
        .first(4).should eq(["cc", "--target=aarch64-linux-musl", "--sysroot", "/opt/sysroots/linux-arm64"])
    end
  end

  # gcc has no --target: it only links for the target it was built for
  # ("unrecognized command-line option '--target=...'", gcc 15.2.0), and a
  # cross gcc is installed under the name of its target.
  it "links with the cross gcc of the target when cc is gcc" do
    Fixture.project(config: CONFIG.sub("linker: zig", "linker: cc")) do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      Crystalreleaser::Builders::Cross.new(ctx.host)
        .link_command(build, build.platforms.first, ctx, [] of String, cc_version: "cc (Alpine 15.2.0) 15.2.0\n")
        .first(3).should eq(["aarch64-linux-musl-gcc", "--sysroot", "/opt/sysroots/linux-arm64"])
    end
  end

  it "fails cleanly without the sysroot" do
    Fixture.project(config: CONFIG.sub("/opt/sysroots", "/nonexistent/sysroots")) do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      expect_raises(Crystalreleaser::BuildError,
        "toy linux/arm64: sysroot not found: /nonexistent/sysroots/linux-arm64 (it must hold the target's " \
        "static libraries; crystalreleaser does not provide it)") do
        Crystalreleaser::Builders::Cross.new(ctx.host).build(build, build.platforms.first, ctx)
      end
    end
  end

  it "cross-compiles for real with the sysroot in CRYSTALRELEASER_SYSROOT", tags: "cross" do
    sysroot = ENV["CRYSTALRELEASER_SYSROOT"]? || fail("set CRYSTALRELEASER_SYSROOT to a linux-arm64 musl sysroot")
    Fixture.project(config: CONFIG.sub("/opt/sysroots/{{ .Os }}-{{ .Arch }}", sysroot).sub("[--release]", "[]")) do |project|
      ctx = spec_context(project, Crystalreleaser::Host.current, env: ENV.to_h)
      build = ctx.config.builds.first
      path = Crystalreleaser::Builders::Cross.new(ctx.host).build(build, build.platforms.first, ctx)
      description = Crystalreleaser::Builders.describe(path.to_s).should_not be_nil
      Crystalreleaser::Builders.file_warnings(description, "linux", "arm64", static: true).should be_empty
    end
  end

  # A program that requires OpenSSL makes crystal print the libraries it
  # looks up with pkg-config as shell command substitutions: the link line
  # this builder has to read for real, not the plain one of a toy.
  it "cross-compiles a program that links OpenSSL", tags: "cross" do
    sysroot = ENV["CRYSTALRELEASER_SYSROOT"]? || fail("set CRYSTALRELEASER_SYSROOT to a linux-arm64 musl sysroot")
    Fixture.project(config: CONFIG.sub("/opt/sysroots/{{ .Os }}-{{ .Arch }}", sysroot).sub("[--release]", "[]")) do |project|
      project.write("src/toy.cr", "require \"openssl\"\nputs OpenSSL::SSL::Context::Client.new.class\n")
      ctx = spec_context(project, Crystalreleaser::Host.current, env: ENV.to_h)
      build = ctx.config.builds.first
      path = Crystalreleaser::Builders::Cross.new(ctx.host).build(build, build.platforms.first, ctx)
      description = Crystalreleaser::Builders.describe(path.to_s).should_not be_nil
      Crystalreleaser::Builders.file_warnings(description, "linux", "arm64", static: true).should be_empty
    end
  end
end
