require "../spec_helper"

# A toy project with one release behind it (v1.0.0) and one commit since,
# built natively for the host without --release to keep the spec fast.
private def released_toy(& : Fixture::Project ->) : Nil
  config = <<-YAML
    builds:
      - id: toy
        target: toy
        flags: []
    changelog:
      groups:
        - title: Features
          regexp: '^feat'
        - title: Bug fixes
          regexp: '^fix'
    YAML
  Fixture.project(config: config) do |project|
    project.write("LICENSE", "MIT\n")
    project.write("README.md", "# toy\n")
    project.write(".gitignore", "/dist/\n")
    project.init_git
    project.commit("feat: first")
    project.tag("v1.0.0")
    project.commit("fix: second")
    yield project
  end
end

private def platform : String
  host = Crystalreleaser::Host.current
  "#{host.os}_#{host.arch}"
end

describe "crystalreleaser release" do
  it "runs a snapshot release end to end without publishing" do
    released_toy do |project|
      run = run_cli_in(project.dir, "release", "--snapshot", "--skip=publish")
      run.code.should eq(0), run.stderr

      short = project.git("rev-parse", "--short=7", "HEAD")
      version = "1.0.1-SNAPSHOT-#{short}"
      archive = "toy_#{version}_#{platform}.tar.gz"

      Dir.children(project.path("dist")).sort.should eq([
        "CHANGELOG.md", "artifacts.json", "checksums.txt", "metadata.json", archive, "toy_#{platform}",
      ].sort)

      # The archive: binary 0755 plus the default files, owned by root,
      # stamped with the commit time.
      entries = read_tar_gz(project.path("dist/#{archive}"))
      entries.map { |entry| {entry.name, entry.mode, entry.uname} }
        .should eq([{"LICENSE", 0o644, "root"}, {"README.md", 0o644, "root"}, {"toy", 0o755, "root"}])
      entries.map(&.mtime).uniq!.should eq([Time.unix(project.commit_time)])

      File.read(project.path("dist/checksums.txt")).should match(/\A[0-9a-f]{64}  #{Regex.escape(archive)}\n\z/)

      fix = project.git("rev-parse", "HEAD")[0, 7]
      File.read(project.path("dist/CHANGELOG.md"))
        .should eq("## Changelog\n\n### Bug fixes\n\n* #{fix} fix: second\n")

      types = JSON.parse(File.read(project.path("dist/artifacts.json"))).as_a.map(&.["type"].as_s)
      types.should eq(["binary", "archive", "checksum"])
      JSON.parse(File.read(project.path("dist/metadata.json")))["version"].should eq(version)

      run.stderr.should contain("• publishing the GitHub release skipped: --skip=publish\n")
    end
  end

  it "is verified by the system tools" do
    released_toy do |project|
      run_cli_in(project.dir, "release", "--snapshot", "--skip=publish").code.should eq(0)
      dist = project.path("dist")
      tool = Process.find_executable("sha256sum") ? ["sha256sum", "-c"] : ["shasum", "-a", "256", "-c"]
      Process.run(tool[0], tool[1..] + ["checksums.txt"], chdir: dist).success?.should be_true

      archive = Dir.children(dist).find!(&.ends_with?(".tar.gz"))
      listing = IO::Memory.new
      Process.run("tar", ["-tvzf", archive], chdir: dist, output: listing).success?.should be_true
      listing.to_s.lines.map(&.split.last).should eq(["LICENSE", "README.md", "toy"])
    end
  end

  it "releases the tagged commit with its tag version" do
    released_toy do |project|
      project.tag("v1.1.0")
      run = run_cli_in(project.dir, "release", "--skip=publish")
      run.code.should eq(0), run.stderr

      File.exists?(project.path("dist/toy_1.1.0_#{platform}.tar.gz")).should be_true
      JSON.parse(File.read(project.path("dist/metadata.json")))["previous_tag"].should eq("v1.0.0")
    end
  end

  it "skips publishing in snapshot mode even without --skip" do
    released_toy do |project|
      run = run_cli_in(project.dir, "release", "--snapshot")
      run.code.should eq(0), run.stderr
      run.stderr.should contain("• publishing the GitHub release skipped: snapshot\n")
    end
  end

  it "rejects an unknown pipe in --skip" do
    released_toy do |project|
      run = run_cli_in(project.dir, "release", "--snapshot", "--skip=publish,nope")
      run.code.should eq(1)
      run.stderr.should end_with(
        "crystalreleaser: unknown pipe in --skip: nope (known: shard, before, " \
        "archive, nfpm, checksum, changelog, metadata, homebrew, aqua, release, publish)\n")
    end
  end

  it "refuses to skip the pipes a release cannot do without" do
    released_toy do |project|
      {"validate", "git", "build"}.each do |pipe|
        run = run_cli_in(project.dir, "release", "--snapshot", "--skip=#{pipe}")
        run.code.should eq(1)
        run.stderr.should end_with("crystalreleaser: #{pipe} cannot be skipped\n")
      end
    end
  end

  it "checks --release-notes before building anything" do
    released_toy do |project|
      run = run_cli_in(project.dir, "release", "--snapshot", "--release-notes", "nope.md")
      run.code.should eq(1)
      run.stderr.should end_with("crystalreleaser: release notes file not found: nope.md\n")
      run.stderr.should_not contain("building binaries")
    end
  end
end

describe "crystalreleaser changelog" do
  it "prints the changelog since the previous tag on stdout" do
    released_toy do |project|
      project.tag("v1.1.0")
      run = run_cli_in(project.dir, "changelog")

      run.code.should eq(0), run.stderr
      fix = project.git("rev-parse", "HEAD")[0, 7]
      run.stdout.should eq("## Changelog\n\n### Bug fixes\n\n* #{fix} fix: second\n")
      Dir.exists?(project.path("dist")).should be_false
    end
  end

  # `release` refuses that clone; `changelog` must not print a changelog cut
  # down to its title instead.
  it "refuses a shallow clone of a tagged commit, as release does" do
    released_toy do |project|
      project.tag("v1.1.0")
      clone = project.path("clone")
      project.git("clone", "-q", "--depth", "1", "--branch", "v1.1.0", "file://#{project.dir}", clone)
      run = run_cli_in(clone, "changelog")

      run.code.should eq(1)
      run.stdout.should be_empty
      run.stderr.should contain("crystalreleaser: this is a shallow clone: the history before v1.1.0 is missing")
    end
  end

  it "reports an invalid configuration as release does, without a backtrace" do
    released_toy do |project|
      File.write(project.path(".crystalreleaser.yml"), "changelog:\n  filters:\n    exclude: [\"(\"]\n")
      run = run_cli_in(project.dir, "changelog")

      run.code.should eq(1)
      run.stdout.should be_empty
      run.stderr.should contain("crystalreleaser: invalid configuration:\n  - changelog.filters.exclude[0]: invalid regular expression")
    end
  end

  it "covers the commits since the last tag on an untagged HEAD" do
    released_toy do |project|
      third = project.commit("feat: third")
      run = run_cli_in(project.dir, "changelog")

      run.code.should eq(0), run.stderr
      fix = project.git("rev-parse", "HEAD~1")[0, 7]
      run.stdout.should eq("## Changelog\n\n### Features\n\n* #{third[0, 7]} feat: third\n\n" \
                           "### Bug fixes\n\n* #{fix} fix: second\n")
    end
  end
end
