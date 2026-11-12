require "../spec_helper"

# The host builds natively; the config also lists a platform no host here
# can build (freebsd), which split mode must leave to another runner.
private def split_toy(& : Fixture::Project ->) : Nil
  host = Crystalreleaser::Host.current
  config = <<-YAML
    builds:
      - id: toy
        target: toy
        flags: []
        platforms:
          - os: #{host.os}
            arch: #{host.arch}
          - os: freebsd
            arch: amd64
            strategy: cross
        cross:
          sysroot: /nonexistent
    YAML
  Fixture.project(config: config) do |project|
    project.write(".gitignore", "/dist/\n")
    project.init_git
    project.commit("feat: first")
    project.tag("v1.0.0")
    yield project
  end
end

private def platform_dir : String
  host = Crystalreleaser::Host.current
  "#{host.os}_#{host.arch}"
end

describe "build --split and release --merge" do
  it "builds this host's share into dist/<os>_<arch>/ with a partial artifacts.json" do
    split_toy do |project|
      run = run_cli_in(project.dir, "build", "--split")
      run.code.should eq(0), run.stderr
      run.stderr.should contain("leaving toy freebsd/amd64 (cross) to another runner")

      Dir.children(project.path("dist")).should eq([platform_dir])
      Dir.children(project.path("dist/#{platform_dir}")).sort.should eq(["artifacts.json", "metadata.json", "toy_#{platform_dir}"])
      artifacts = JSON.parse(File.read(project.path("dist/#{platform_dir}/artifacts.json"))).as_a
      artifacts.map(&.["path"].as_s).should eq(["dist/#{platform_dir}/toy_#{platform_dir}/toy"])
      # What the merge checks the binary against once it has travelled.
      artifacts.map(&.["sha256"].as_s)
        .should eq([Digest::SHA256.hexdigest(File.read(project.path("dist/#{platform_dir}/toy_#{platform_dir}/toy")))])
      JSON.parse(File.read(project.path("dist/#{platform_dir}/metadata.json")))["commit"]
        .should eq(project.git("rev-parse", "HEAD"))
    end
  end

  it "builds nothing for a platform filtered out with --os" do
    split_toy do |project|
      run = run_cli_in(project.dir, "build", "--split", "--os", "plan9")
      run.code.should eq(1)
      run.stderr.should contain("nothing to build for this host")
    end
  end

  it "refuses to merge with a platform missing, unless --allow-missing" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)

      refused = run_cli_in(project.dir, "release", "--merge", "--skip=publish")
      refused.code.should eq(1)
      refused.stderr.should end_with(
        "crystalreleaser: missing platforms: toy freebsd/amd64 (use --allow-missing to release without them)\n")

      merged = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      merged.code.should eq(0), merged.stderr
      merged.stderr.should contain("⚠ missing platforms: toy freebsd/amd64\n")
      File.exists?(project.path("dist/toy_1.0.0_#{platform_dir}.tar.gz")).should be_true
      File.exists?(project.path("dist/checksums.txt")).should be_true
    end
  end

  it "makes the merged binaries executable again, as an artifact transfer drops the bit" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      binary = project.path("dist/#{platform_dir}/toy_#{platform_dir}/toy")
      File.chmod(binary, 0o644)

      merged = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      merged.code.should eq(0), merged.stderr
      File.info(binary).permissions.value.should eq(0o755)
      entry = read_tar_gz(project.path("dist/toy_1.0.0_#{platform_dir}.tar.gz")).find!(&.name.==("toy"))
      entry.mode.should eq(0o755)
    end
  end

  it "refuses a binary whose size is not the one its runner recorded" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      File.write(project.path("dist/#{platform_dir}/toy_#{platform_dir}/toy"), "cut")

      run = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      run.code.should eq(1)
      run.stderr.should match(/crystalreleaser: dist\/#{platform_dir}: dist\/#{platform_dir}\/toy_#{platform_dir}\/toy is 3 bytes, \d+ were built: incomplete transfer\?\n\z/)
    end
  end

  it "refuses an artifacts.json pointing outside its own folder" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      list = project.path("dist/#{platform_dir}/artifacts.json")
      File.write(list, File.read(list).sub("dist/#{platform_dir}/toy_#{platform_dir}/toy", "shard.yml"))

      run = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      run.code.should eq(1)
      run.stderr.should end_with("crystalreleaser: dist/#{platform_dir}: shard.yml is outside this split build\n")
      File.info(project.path("shard.yml")).permissions.value.should eq(0o644)
    end
  end

  it "reports an incomplete metadata.json without a backtrace" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      File.write(project.path("dist/#{platform_dir}/metadata.json"), "{}\n")

      run = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      run.code.should eq(1)
      run.stderr.should end_with("crystalreleaser: cannot read the split build in dist/#{platform_dir}: metadata.json has no commit\n")
    end
  end

  it "refuses split builds of another commit" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      project.commit("feat: second")
      project.tag("v1.1.0")

      run = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      run.code.should eq(1)
      run.stderr.should contain("crystalreleaser: dist/#{platform_dir} was built from commit ")
    end
  end

  it "rejects --clean with --merge, and --os without --split" do
    split_toy do |project|
      run_cli_in(project.dir, "release", "--merge", "--clean").stderr
        .should end_with("crystalreleaser: --clean cannot be combined with --merge\n")
      run_cli_in(project.dir, "build", "--os", "linux").stderr
        .should end_with("crystalreleaser: --os and --arch need --split\n")
    end
  end
end
