require "../spec_helper"

describe Crystalreleaser::VersionInfo do
  it "splits a release tag into its parts" do
    info = Crystalreleaser::VersionInfo.release("v1.2.3-rc.1")
    {info.tag, info.version, info.raw_version, info.major, info.minor, info.patch, info.prerelease, info.snapshot?}
      .should eq({"v1.2.3-rc.1", "1.2.3-rc.1", "1.2.3", "1", "2", "3", "rc.1", false})
  end

  it "accepts a tag without the v prefix" do
    Crystalreleaser::VersionInfo.release("2.0.0").version.should eq("2.0.0")
  end

  it "builds a snapshot version from the next patch of the last tag" do
    info = Crystalreleaser::VersionInfo.snapshot("v1.4.2", "abc1234")
    {info.tag, info.version, info.raw_version, info.patch, info.prerelease, info.snapshot?}
      .should eq({"v1.4.3-SNAPSHOT-abc1234", "1.4.3-SNAPSHOT-abc1234", "1.4.3", "3", "SNAPSHOT-abc1234", true})
  end

  it "starts snapshots at 0.0.1 when there is no tag yet" do
    Crystalreleaser::VersionInfo.snapshot(nil, "abc1234").version.should eq("0.0.1-SNAPSHOT-abc1234")
  end

  it "rejects a tag that is not semver" do
    expect_raises(Crystalreleaser::GitError, "tag 'latest' is not a semver version") do
      Crystalreleaser::VersionInfo.release("latest")
    end
  end
end

describe Crystalreleaser::Context do
  it "exposes every global template variable" do
    Fixture.project do |project|
      spec_context(project).vars.should eq({
        "ProjectName"    => "toy",
        "Version"        => "1.2.3-rc.1",
        "RawVersion"     => "1.2.3",
        "Tag"            => "v1.2.3-rc.1",
        "PreviousTag"    => "v1.2.2",
        "Major"          => "1",
        "Minor"          => "2",
        "Patch"          => "3",
        "Prerelease"     => "rc.1",
        "Commit"         => "0123456789abcdef0123456789abcdef01234567",
        "ShortCommit"    => "0123456",
        "Branch"         => "master",
        "Date"           => "2026-11-12T08:30:00Z",
        "Timestamp"      => "1794472200",
        "CrystalVersion" => "1.20.3",
        "IsSnapshot"     => "false",
      })
    end
  end

  it "adds the platform variables for a build" do
    Fixture.project do |project|
      ctx = spec_context(project)
      build = ctx.config.builds.first
      platform = Crystalreleaser::Config::Platform.new("linux", "arm64", "docker", true)
      ctx.platform_vars(build, platform).select("Os", "Arch", "Target", "Binary")
        .should eq({"Os" => "linux", "Arch" => "arm64", "Target" => "aarch64-linux-musl", "Binary" => "toy"})
    end
  end

  it "renders the build environment from env: and builds[].env:" do
    config = <<-YAML
      env:
        - GLOBAL={{ .ProjectName }}
      builds:
        - id: toy
          target: toy
          env:
            - TOY_VERSION={{ .Version }}
            - TOY_TARGET={{ .Os }}-{{ .Arch }}
      YAML
    Fixture.project(config: config) do |project|
      ctx = spec_context(project, env: {"PATH" => "/bin", "GLOBAL" => "overridden"})
      build = ctx.config.builds.first
      ctx.build_env(build, build.platforms.first).should eq({
        "PATH"        => "/bin",
        "GLOBAL"      => "toy",
        "TOY_VERSION" => "1.2.3-rc.1",
        "TOY_TARGET"  => "linux-amd64",
      })
    end
  end

  it "resolves paths under the dist directory of the project" do
    Fixture.project(config: "dist: out\n") do |project|
      spec_context(project).dist_path("toy_linux_amd64", "toy")
        .should eq(File.join(project.dir, "out", "toy_linux_amd64", "toy"))
    end
  end
end
