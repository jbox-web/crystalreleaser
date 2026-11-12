require "../../spec_helper"

private def add_archive(ctx : Crystalreleaser::Context, name : String, content : String) : Nil
  path = ctx.dist_path(name)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
  ctx.artifacts.add(Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Archive, name, ctx.relative(path)))
end

describe Crystalreleaser::Pipes::Checksum do
  it "refuses a name that would be written outside dist/" do
    Fixture.project(config: "checksum:\n  name_template: ../sums.txt\n") do |project|
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Archive.new.run(ctx)
      expect_raises(Crystalreleaser::PackageError, %(checksum.name_template: "../sums.txt" is not a plain file name)) do
        Crystalreleaser::Pipes::Checksum.new.run(ctx)
      end
    end
  end

  it "writes sha256sum lines sorted by name, two spaces apart" do
    Fixture.project do |project|
      ctx = spec_context(project)
      add_archive(ctx, "toy_linux.tar.gz", "linux")
      add_archive(ctx, "toy_darwin.tar.gz", "darwin")
      Crystalreleaser::Pipes::Checksum.new.run(ctx)

      # sha256("darwin") and sha256("linux"), from `printf darwin | sha256sum`.
      File.read(project.path("dist/checksums.txt")).should eq(
        "26ce1a1580f693873b6268fef54c5f0d0607f2896cad02ce2894c0c899a11575  toy_darwin.tar.gz\n" \
        "caf90169eefa5f807d577486b9f795ab86ae2983c5c20806cff959117e90af18  toy_linux.tar.gz\n")
    end
  end

  describe "with split: true" do
    # One file per asset, named after it, in the format of `sha256sum`: what
    # a script that fetches one binary checks it against.
    it "writes one <asset>.sha256 per asset and no combined file" do
      Fixture.project(config: "checksum:\n  split: true\n") do |project|
        ctx = spec_context(project)
        add_archive(ctx, "toy-linux-amd64", "linux")
        add_archive(ctx, "toy-darwin-arm64", "darwin")
        Crystalreleaser::Pipes::Checksum.new.run(ctx)

        # sha256("darwin") and sha256("linux"), from `printf darwin | sha256sum`.
        File.read(project.path("dist/toy-darwin-arm64.sha256"))
          .should eq("26ce1a1580f693873b6268fef54c5f0d0607f2896cad02ce2894c0c899a11575  toy-darwin-arm64\n")
        File.read(project.path("dist/toy-linux-amd64.sha256"))
          .should eq("caf90169eefa5f807d577486b9f795ab86ae2983c5c20806cff959117e90af18  toy-linux-amd64\n")
        File.exists?(project.path("dist/checksums.txt")).should be_false

        ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Checksum).map { |artifact| {artifact.name, artifact.path} }.should eq([
          {"toy-darwin-arm64.sha256", "dist/toy-darwin-arm64.sha256"},
          {"toy-linux-amd64.sha256", "dist/toy-linux-amd64.sha256"},
        ])
        ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).map(&.sha256).should eq([
          "caf90169eefa5f807d577486b9f795ab86ae2983c5c20806cff959117e90af18",
          "26ce1a1580f693873b6268fef54c5f0d0607f2896cad02ce2894c0c899a11575",
        ])
      end
    end

    it "is verified by the system sha256 tool, file by file" do
      tool = Process.find_executable("sha256sum") ? ["sha256sum", "-c"] : ["shasum", "-a", "256", "-c"]
      Fixture.project(config: "checksum:\n  split: true\n") do |project|
        ctx = spec_context(project)
        add_archive(ctx, "a.tar.gz", "aaa")
        Crystalreleaser::Pipes::Checksum.new.run(ctx)
        Process.run(tool[0], tool[1..] + ["a.tar.gz.sha256"], chdir: ctx.dist_path,
          output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true
      end
    end
  end

  it "is verified by the system sha256 tool" do
    tool = Process.find_executable("sha256sum") ? ["sha256sum", "-c"] : ["shasum", "-a", "256", "-c"]
    Fixture.project do |project|
      ctx = spec_context(project)
      add_archive(ctx, "a.tar.gz", "aaa")
      add_archive(ctx, "b.tar.gz", "bbb")
      Crystalreleaser::Pipes::Checksum.new.run(ctx)

      status = Process.run(tool[0], tool[1..] + ["checksums.txt"], chdir: ctx.dist_path,
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?.should be_true
    end
  end

  it "records the checksum file and each hash" do
    Fixture.project do |project|
      ctx = spec_context(project)
      add_archive(ctx, "a.tar.gz", "aaa")
      Crystalreleaser::Pipes::Checksum.new.run(ctx)

      checksum = ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Checksum).first
      {checksum.name, checksum.path}.should eq({"checksums.txt", "dist/checksums.txt"})
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).first.sha256
        .should eq("9834876dcfb05cb167a5c24953eba58c4ac89b1adf57f28f2f9d09af107ee8f0")
    end
  end

  it "is skipped when there is nothing to checksum" do
    Fixture.project do |project|
      Crystalreleaser::Pipes::Checksum.new.skip?(spec_context(project)).should eq("no archives or packages")
    end
  end
end
