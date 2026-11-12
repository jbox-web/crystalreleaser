require "../../spec_helper"

private CONFIG = <<-YAML
  builds:
    - id: toy
      target: toy
      flags: [--release]
      env:
        - TOY_VERSION={{ .Version }}
      platforms:
        - os: linux
          arch: arm64
          strategy: docker
          static: true
  YAML

private def docker_context(project, host = Crystalreleaser::Host.new("linux", "amd64", musl: false))
  ctx = spec_context(project, host)
  {ctx, ctx.config.builds.first, ctx.config.builds.first.platforms.first}
end

# The first 12 hex digits of the sha256 of the project path, which keeps the
# volumes of two projects apart.
private def project_key(project) : String
  Digest::SHA256.hexdigest(project.dir)[0, 12]
end

describe Crystalreleaser::Builders::Docker do
  it "runs the static build in the image as the calling user, with caches of its own" do
    Fixture.project(config: CONFIG) do |project|
      ctx, build, platform = docker_context(project)
      builder = Crystalreleaser::Builders::Docker.new(ctx.host)
      key = project_key(project)

      builder.command(build, platform, ctx, 1000_u32, 1001_u32).should eq([
        "docker", "run", "--rm", "--platform", "linux/arm64",
        "--user", "1000:1001",
        "-v", "#{project.dir}:/src", "-w", "/src",
        "-v", "crystalreleaser-cache-arm64-#{key}:/cache",
        "-v", "crystalreleaser-lib-arm64-#{key}-toy:/src/lib",
        "-e", "HOME=/cache/home", "-e", "CRYSTAL_CACHE_DIR=/cache/crystal",
        "-e", "TOY_VERSION",
        "--entrypoint", "sh", "84codes/crystal:1.20.3-alpine", "-c",
        "shards install && rm -f shard.lock && " \
        "crystal build src/toy.cr -o /src/dist/toy_linux_arm64/toy --release --static",
      ])
    end
  end

  # Without a shard.lock, `shards install` writes one in the project, which
  # is mounted: two docker builds would write it at once, and it would leave
  # the tree dirty for the next release. Which case applies is decided on the
  # host, once, not by each container looking at a file the others create.
  it "installs from shard.lock when the project has one, and leaves none behind otherwise" do
    Fixture.project(config: CONFIG) do |project|
      ctx, build, platform = docker_context(project)
      builder = Crystalreleaser::Builders::Docker.new(ctx.host)
      builder.command(build, platform, ctx).last.should start_with("shards install && rm -f shard.lock && crystal build ")

      project.write("shard.lock", "version: 2.0\nshards: {}\n")
      builder.command(build, platform, ctx).last.should start_with("shards install --production && crystal build ")
    end
  end

  it "passes the values of env: through the docker process, not on its command line" do
    Fixture.project(config: CONFIG) do |project|
      ctx, build, platform = docker_context(project)
      builder = Crystalreleaser::Builders::Docker.new(ctx.host)
      builder.command(build, platform, ctx, 1_u32, 1_u32).join(' ').should_not contain("1.2.3-rc.1")
      builder.environment(build, platform, ctx).should eq({"TOY_VERSION" => "1.2.3-rc.1"})
    end
  end

  it "gives two builds of a project, and two projects, volumes of their own" do
    two = CONFIG + "\n  - id: other\n    main: src/toy.cr\n    platforms:\n      - os: linux\n        arch: arm64\n        strategy: docker\n"
    Fixture.project(config: two) do |project|
      ctx = spec_context(project)
      builder = Crystalreleaser::Builders::Docker.new(ctx.host)
      toy, other = ctx.config.builds
      key = project_key(project)
      builder.lib_volume(toy, toy.platforms.first, ctx).should eq("crystalreleaser-lib-arm64-#{key}-toy")
      builder.lib_volume(other, other.platforms.first, ctx).should eq("crystalreleaser-lib-arm64-#{key}-other")
      builder.cache_volume(toy.platforms.first, ctx).should eq("crystalreleaser-cache-arm64-#{key}")
    end
  end

  it "hands the cache volumes to the user first, as root" do
    Fixture.project(config: CONFIG) do |project|
      ctx, build, platform = docker_context(project)
      key = project_key(project)
      Crystalreleaser::Builders::Docker.new(ctx.host).prepare_command(build, platform, ctx, 1000_u32, 1001_u32).should eq([
        "docker", "run", "--rm", "--platform", "linux/arm64",
        "-v", "crystalreleaser-cache-arm64-#{key}:/cache", "-v", "crystalreleaser-lib-arm64-#{key}-toy:/lib-cache",
        "--entrypoint", "chown", "84codes/crystal:1.20.3-alpine", "-R", "1000:1001", "/cache", "/lib-cache",
      ])
    end
  end

  it "can skip the platform flag and shards install" do
    config = CONFIG + "\n    docker:\n      platform_flag: false\n      shards_install: false\n      image: my/crystal:{{ .Arch }}\n"
    Fixture.project(config: config) do |project|
      ctx, build, platform = docker_context(project)
      command = Crystalreleaser::Builders::Docker.new(ctx.host).command(build, platform, ctx, 1_u32, 1_u32)
      command.should_not contain("--platform")
      command[-3].should eq("my/crystal:arm64")
      command.last.should eq("crystal build src/toy.cr -o /src/dist/toy_linux_arm64/toy --release --static")
    end
  end

  it "quotes arguments for the shell" do
    config = CONFIG.sub("flags: [--release]", %(flags: ["-Dfoo bar"]))
    Fixture.project(config: config) do |project|
      ctx, build, platform = docker_context(project)
      Crystalreleaser::Builders::Docker.new(ctx.host).command(build, platform, ctx, 1_u32, 1_u32).last
        .should end_with(%(-o /src/dist/toy_linux_arm64/toy '-Dfoo bar' --static))
    end
  end

  it "is serial only when emulated" do
    Fixture.project(config: CONFIG) do |project|
      ctx, _, platform = docker_context(project)
      Crystalreleaser::Builders::Docker.new(Crystalreleaser::Host.new("linux", "amd64", musl: false)).serial?(platform, ctx).should be_true
      Crystalreleaser::Builders::Docker.new(Crystalreleaser::Host.new("linux", "arm64", musl: false)).serial?(platform, ctx).should be_false
    end
  end

  it "builds a static linux binary for real", tags: "docker" do
    host = Crystalreleaser::Host.current
    config = <<-YAML
      builds:
        - id: toy
          target: toy
          flags: []
          platforms:
            - os: linux
              arch: #{host.arch}
              strategy: docker
              static: true
      YAML
    Fixture.project(config: config) do |project|
      ctx = spec_context(project, host, env: ENV.to_h)
      ctx.crystal_version = "1.20.3"
      build = ctx.config.builds.first
      platform = build.platforms.first
      builder = Crystalreleaser::Builders::Docker.new(host)
      begin
        path = builder.build(build, platform, ctx)

        description = Crystalreleaser::Builders.describe(path.to_s).should_not be_nil
        Crystalreleaser::Builders.file_warnings(description, "linux", host.arch, static: true).should be_empty
        File.info(path).owner_id.should eq(LibC.getuid.to_s)
      ensure
        # The volumes are named after the project, here a throw-away
        # directory: left behind, every run would add two.
        Process.run("docker", ["volume", "rm", builder.cache_volume(platform, ctx), builder.lib_volume(build, platform, ctx)],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
    end
  end
end
