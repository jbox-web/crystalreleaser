require "../spec_helper"

# These examples compile real binaries with the host's crystal, natively: the
# toy program takes about a second to build without --release.
private TOY_SHARD = <<-YAML
  name: toy
  version: 0.1.0
  targets:
    toy:
      main: src/toy.cr
    other:
      main: src/other.cr
  YAML

private TOY_CONFIG = <<-YAML
  builds:
    - id: toy
      target: toy
      flags: []
      env:
        - TOY_VERSION={{ .Version }}
  YAML

private def host_dir(id : String) : String
  host = Crystalreleaser::Host.current
  "#{id}_#{host.os}_#{host.arch}"
end

private def toy_project(config = TOY_CONFIG, & : Fixture::Project ->) : Nil
  Fixture.project(shard: TOY_SHARD, config: config) do |project|
    # The version is injected at compile time through the build env, as the
    # README documents for every project.
    project.write("src/toy.cr", %(puts {{ env("TOY_VERSION") || "dev" }}\n))
    project.write("src/other.cr", %(puts "other"\n))
    project.write(".gitignore", "/dist/\n")
    project.init_git
    project.commit("initial")
    yield project
  end
end

describe "crystalreleaser build" do
  it "builds a snapshot natively and injects the version" do
    toy_project do |project|
      run = run_cli_in(project.dir, "build", "--snapshot")
      run.code.should eq(0), run.stderr

      binary = project.path("dist/#{host_dir("toy")}/toy")
      File.info(binary).permissions.owner_execute?.should be_true
      short = project.git("rev-parse", "--short=7", "HEAD")
      `#{binary}`.should eq("0.0.1-SNAPSHOT-#{short}\n")
      run.stderr.should contain("• building binaries\n")
    end
  end

  it "builds several builds in parallel" do
    config = TOY_CONFIG + "\n  - id: other\n    target: other\n    flags: []\n"
    toy_project(config) do |project|
      run = run_cli_in(project.dir, "build", "--snapshot", "--parallelism", "2")
      run.code.should eq(0), run.stderr

      File.exists?(project.path("dist/#{host_dir("toy")}/toy")).should be_true
      File.exists?(project.path("dist/#{host_dir("other")}/other")).should be_true
    end
  end

  it "rejects an --id no build carries, before building anything" do
    toy_project(TOY_CONFIG) do |project|
      run = run_cli_in(project.dir, "build", "--snapshot", "--id", "nope")
      run.code.should eq(1)
      run.stderr.should end_with("crystalreleaser: unknown build id in --id: nope\n")
      Dir.children(project.path("dist")).should be_empty
    end
  end

  it "builds only the ids given with --id" do
    config = TOY_CONFIG + "\n  - id: other\n    target: other\n    flags: []\n"
    toy_project(config) do |project|
      run_cli_in(project.dir, "build", "--snapshot", "--id", "other").code.should eq(0)

      Dir.children(project.path("dist")).should eq([host_dir("other")])
    end
  end

  it "refuses a dirty dist/ without --clean, and empties it with --clean" do
    toy_project do |project|
      project.write("dist/stale.txt", "x")

      refused = run_cli_in(project.dir, "build", "--snapshot")
      refused.code.should eq(1)
      refused.stderr.should end_with("crystalreleaser: dist/ is not empty: remove it or use --clean\n")

      run_cli_in(project.dir, "build", "--snapshot", "--clean").code.should eq(0)
      File.exists?(project.path("dist/stale.txt")).should be_false
    end
  end

  it "requires a tag outside snapshot mode" do
    toy_project do |project|
      run = run_cli_in(project.dir, "build")
      run.code.should eq(1)
      run.stderr.should end_with(
        "crystalreleaser: HEAD is not tagged: tag it with a semver version (e.g. v1.0.0) or use --snapshot\n")
    end
  end

  it "reports a compilation failure with the compiler output" do
    toy_project do |project|
      project.write("src/toy.cr", "undefined_method_for_sure\n")
      project.commit("break")
      run = run_cli_in(project.dir, "build", "--snapshot")

      run.code.should eq(1)
      run.stderr.should contain("crystalreleaser: build failed:\n  - toy #{Crystalreleaser::Host.current}: ")
      run.stderr.should contain("undefined local variable or method 'undefined_method_for_sure'")
    end
  end
end
