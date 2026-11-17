require "../../spec_helper"

private def platform(os = "linux", arch = "amd64", static = false) : Crystalreleaser::Config::Platform
  Crystalreleaser::Config::Platform.new(os, arch, "native", static)
end

describe Crystalreleaser::Builders::Native do
  it "compiles the main file into dist/<id>_<os>_<arch>/<binary> with the build flags" do
    Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n    flags: [--release, --no-debug]\n") do |project|
      host = Crystalreleaser::Host.new("linux", "amd64", musl: false)
      ctx = spec_context(project, host)
      builder = Crystalreleaser::Builders::Native.new(host)

      builder.command(ctx.config.builds.first, platform, ctx).should eq([
        "crystal", "build", "src/toy.cr",
        "-o", File.join(project.dir, "dist", "toy_linux_amd64", "toy"),
        "--release", "--no-debug",
      ])
    end
  end

  it "adds --static on a musl host" do
    Fixture.project do |project|
      host = Crystalreleaser::Host.new("linux", "arm64", musl: true)
      ctx = spec_context(project, host)
      builder = Crystalreleaser::Builders::Native.new(host)

      builder.command(ctx.config.builds.first, platform("linux", "arm64", static: true), ctx).last.should eq("--static")
    end
  end

  it "refuses a static build on a glibc host and suggests docker" do
    Fixture.project do |project|
      host = Crystalreleaser::Host.new("linux", "amd64", musl: false)
      ctx = spec_context(project, host)
      builder = Crystalreleaser::Builders::Native.new(host)

      expect_raises(Crystalreleaser::BuildError,
        "toy linux/amd64: static linking needs a musl host (e.g. Alpine), this one uses glibc; use strategy: docker") do
        builder.command(ctx.config.builds.first, platform(static: true), ctx)
      end
    end
  end

  # A Homebrew formula's .a files, copied into a folder of their own that
  # comes first on the linker's search path: ld64 links the first library of
  # that name it finds, and has no "static for this one only" switch. The
  # path is absolute: the linker runs in the compiler's cache.
  describe "static_libs on darwin" do
    config = "builds:\n  - id: toy\n    target: toy\n    static_libs:\n      formula: openssl@4\n      libs: [ssl, crypto]\n"

    it "copies lib<name>.a of the formula into a folder outside the project, first on the linker's path" do
      Fixture.project(config: config) do |project|
        prefix = File.join(project.dir, "fake-homebrew", "openssl@4")
        project.write("fake-homebrew/openssl@4/lib/libssl.a", "ssl archive")
        project.write("fake-homebrew/openssl@4/lib/libcrypto.a", "crypto archive")
        project.write("fake-homebrew/openssl@4/lib/libssl.dylib", "not to be copied")
        host = Crystalreleaser::Host.new("darwin", "arm64", musl: false)
        ctx = spec_context(project, host)
        build = ctx.config.builds.first
        formulas = [] of String
        builder = Crystalreleaser::Builders::Native.new(host, ->(formula : String) { formulas << formula; prefix.as(String?) })

        dir = builder.static_libs_dir(build, platform("darwin", "arm64"), ctx).should_not be_nil
        begin
          formulas.should eq(["openssl@4"])
          Path[dir].absolute?.should be_true
          dir.starts_with?(project.dir).should be_false
          Dir.children(dir).sort.should eq(["libcrypto.a", "libssl.a"])
          File.read(File.join(dir, "libssl.a")).should eq("ssl archive")
          command = builder.command(build, platform("darwin", "arm64"), ctx, dir)
          command.last(2).should eq(["--link-flags", "-L#{dir}"])
        ensure
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "fails before compiling when the formula is not installed, naming it" do
      Fixture.project(config: config) do |project|
        host = Crystalreleaser::Host.new("darwin", "amd64", musl: false)
        ctx = spec_context(project, host)
        builder = Crystalreleaser::Builders::Native.new(host, ->(_formula : String) { nil.as(String?) })
        expect_raises(Crystalreleaser::BuildError,
          "toy darwin/amd64: static_libs: Homebrew has no openssl@4 installed; install it with `brew install openssl@4`") do
          builder.static_libs_dir(ctx.config.builds.first, platform("darwin", "amd64"), ctx)
        end
      end
    end

    it "fails before compiling when a library is missing from the formula, naming both" do
      Fixture.project(config: config) do |project|
        prefix = File.join(project.dir, "fake-homebrew", "openssl@4")
        project.write("fake-homebrew/openssl@4/lib/libssl.a", "ssl archive")
        host = Crystalreleaser::Host.new("darwin", "arm64", musl: false)
        ctx = spec_context(project, host)
        builder = Crystalreleaser::Builders::Native.new(host, ->(_formula : String) { prefix.as(String?) })
        expect_raises(Crystalreleaser::BuildError,
          "toy darwin/arm64: static_libs: openssl@4 has no libcrypto.a in #{prefix}/lib") do
          builder.static_libs_dir(ctx.config.builds.first, platform("darwin", "arm64"), ctx)
        end
      end
    end

    # The linux builds link statically already (musl, in the Alpine image).
    it "does nothing on another os" do
      Fixture.project(config: config) do |project|
        host = Crystalreleaser::Host.new("linux", "amd64", musl: false)
        ctx = spec_context(project, host)
        called = false
        builder = Crystalreleaser::Builders::Native.new(host, ->(_formula : String) { called = true; nil.as(String?) })
        builder.static_libs_dir(ctx.config.builds.first, platform, ctx).should be_nil
        called.should be_false
        builder.command(ctx.config.builds.first, platform, ctx).should_not contain("--link-flags")
      end
    end
  end

  it "is available when crystal is on the PATH" do
    Crystalreleaser::Builders::Native.new(Crystalreleaser::Host.current).available?.should be_true
  end
end
