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

  it "is available when crystal is on the PATH" do
    Crystalreleaser::Builders::Native.new(Crystalreleaser::Host.current).available?.should be_true
  end
end
