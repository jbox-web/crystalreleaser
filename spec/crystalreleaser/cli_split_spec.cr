require "../spec_helper"

# The host builds natively; the config also lists a platform no host here
# can build (freebsd), which split mode must leave to another runner.
private def split_toy(aliases : String = "", & : Fixture::Project ->) : Nil
  host = Crystalreleaser::Host.current
  config = <<-YAML
    builds:
      - id: toy
        target: toy
        flags: []
    #{aliases}
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

  # The aliases of a build travel in the extra of its binary, with the target
  # triple: the machine that merges needs nothing else to write them.
  it "carries the aliases of a build through the split into the archive of the merge" do
    split_toy("    aliases: [toy-manager]") do |project|
      split = run_cli_in(project.dir, "build", "--split")
      split.code.should eq(0), split.stderr
      artifacts = JSON.parse(File.read(project.path("dist/#{platform_dir}/artifacts.json"))).as_a
      artifacts.map(&.["extra"]["aliases"].as_s).should eq(["toy-manager"])

      merged = run_cli_in(project.dir, "release", "--merge", "--allow-missing", "--skip=publish")
      merged.code.should eq(0), merged.stderr
      entries = read_tar_gz(project.path("dist/toy_1.0.0_#{platform_dir}.tar.gz"))
      entries.map { |entry| {entry.name, entry.type} }.select { |(name, _)| name.starts_with?("toy") }
        .should eq([{"toy", '0'}, {"toy-manager", '2'}])
    end
  end

  # Two linux runners, whose share is written by hand as `build --split`
  # leaves it (no docker here): the merge has only artifacts.json to learn
  # the aliases from, and must write them in every format.
  it "writes the aliases of a merged release of two split builds in the archives, packages and aqua entry" do
    config = <<-YAML
      builds:
        - id: toy
          target: toy
          aliases: [toy-manager]
          platforms:
            - { os: linux, arch: amd64, strategy: docker, static: true }
            - { os: linux, arch: arm64, strategy: docker, static: true }
      archives:
        - id: default
          files: []
      nfpms:
        - id: packages
          formats: [deb, rpm]
          maintainer: Jane Doe <jane@example.com>
          bindir: /usr/bin
      release:
        github: { owner: jbox-web, name: toy }
      aqua:
        - repository: { owner: jbox-web, name: aqua-registry, branch: main }
          path: pkgs/jbox-web/toy/registry.yaml
      YAML
    Fixture.project(config: config) do |project|
      project.write(".gitignore", "/dist/\n")
      project.init_git
      project.commit("feat: first")
      project.tag("v1.0.0")
      commit = project.git("rev-parse", "HEAD")
      {"amd64", "arm64"}.each do |arch|
        folder = "dist/linux_#{arch}"
        binary = project.path("#{folder}/toy_linux_#{arch}/toy")
        project.write("#{folder}/toy_linux_#{arch}/toy", "toy for linux/#{arch}")
        File.write(project.path("#{folder}/artifacts.json"), [{
          "type" => "binary", "name" => "toy", "path" => "#{folder}/toy_linux_#{arch}/toy", "os" => "linux",
          "arch" => arch, "build_id" => "toy", "size" => 19,
          "extra" => {"target" => Crystalreleaser::Builders.triple("linux", arch, true), "aliases" => "toy-manager"},
          "sha256" => Digest::SHA256.hexdigest(File.read(binary)),
        }].to_json)
        File.write(project.path("#{folder}/metadata.json"),
          {version: "1.0.0", tag: "v1.0.0", commit: commit, os: "linux", arch: arch}.to_json)
      end

      merged = run_cli_in(project.dir, "release", "--merge", "--skip=publish")
      merged.code.should eq(0), merged.stderr

      {"amd64", "arm64"}.each do |arch|
        read_tar_gz(project.path("dist/toy_1.0.0_linux_#{arch}.tar.gz")).map { |entry| {entry.name, entry.type} }
          .should eq([{"toy", '0'}, {"toy-manager", '2'}])
        deb = File.open(project.path("dist/toy_1.0.0_#{arch}.deb")) { |file| Crystalreleaser::Formats::Ar.read(file) }.last
        Compress::Gzip::Reader.open(IO::Memory.new(deb.content)) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
          .select(&.type.==('2')).map(&.name).should eq(["./usr/bin/toy-manager"])
        header = File.open(project.path("dist/toy_1.0.0_#{arch}.rpm")) { |file| Crystalreleaser::Formats::Rpm.read(file) }[2]
        header[Crystalreleaser::Formats::Rpm::Tag::BASENAMES].should eq(["toy", "toy-manager"])
        header[Crystalreleaser::Formats::Rpm::Tag::FILELINKTOS].should eq(["", "toy"])
      end
      YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]["files"]
        .should eq(YAML.parse("[{name: toy}, {name: toy-manager, src: toy}]"))
    end
  end

  it "records no aliases on the binary of a build without any" do
    split_toy do |project|
      run_cli_in(project.dir, "build", "--split").code.should eq(0)
      artifacts = JSON.parse(File.read(project.path("dist/#{platform_dir}/artifacts.json"))).as_a
      artifacts.map(&.["extra"].as_h.has_key?("aliases")).should eq([false])
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
