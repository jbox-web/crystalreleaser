require "../spec_helper"

private HOST = Crystalreleaser::Host.new("linux", "amd64", musl: false)

private def load(project : Fixture::Project, path : String? = nil) : Crystalreleaser::Config
  Crystalreleaser::Config.load(project.dir, path, HOST)
end

private def config_error(project : Fixture::Project, path : String? = nil) : String
  expect_raises(Crystalreleaser::ConfigError) { load(project, path) }.message.to_s
end

describe Crystalreleaser::Config do
  describe "defaults derived from shard.yml" do
    it "builds every shard target natively for the host when there is no config file" do
      Fixture.project do |project|
        config = load(project)

        config.project_name.should eq("toy")
        config.dist.should eq("dist")
        config.builds.size.should eq(1)
        build = config.builds.first
        build.id.should eq("toy")
        build.target.should eq("toy")
        build.main.should eq("src/toy.cr")
        build.binary.should eq("toy")
        build.flags.should eq(["--release"])
        build.platforms.map { |platform| {platform.os, platform.arch, platform.strategy, platform.static?} }
          .should eq([{"linux", "amd64", "native", false}])
      end
    end

    it "creates one build per shard target" do
      shard = <<-YAML
        name: duo
        version: 1.0.0
        targets:
          alpha:
            main: src/alpha.cr
          beta:
            main: src/beta.cr
        YAML
      Fixture.project(shard: shard) do |project|
        load(project).builds.map { |build| {build.id, build.main, build.binary} }
          .should eq([{"alpha", "src/alpha.cr", "alpha"}, {"beta", "src/beta.cr", "beta"}])
      end
    end

    it "treats an empty config file like a missing one" do
      Fixture.project(config: "") do |project|
        load(project).builds.map(&.id).should eq(["toy"])
      end
    end

    it "fills an archive, a checksum and a changelog by default" do
      Fixture.project do |project|
        config = load(project)

        archive = config.archives.first
        archive.id.should eq("default")
        archive.builds.should eq(["toy"])
        archive.formats.should eq(["tar.gz"])
        archive.name_template.should eq("{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}")
        config.checksum.name_template.should eq("checksums.txt")
        config.checksum.algorithm.should eq("sha256")
        config.changelog.use.should eq("git")
        config.changelog.sort.should eq("asc")
        config.release.prerelease.should eq("auto")
        config.release.name_template.should eq("{{ .Tag }}")
      end
    end

    it "resolves main and binary of an explicit build from its target" do
      config = <<-YAML
        builds:
          - id: main
            target: toy
            platforms:
              - os: linux
                arch: arm64
                strategy: docker
                static: true
        YAML
      Fixture.project(config: config) do |project|
        build = load(project).builds.first
        build.main.should eq("src/toy.cr")
        build.binary.should eq("toy")
        {build.docker.image, build.docker.dockerfile, build.docker.alpine}.should eq({nil, nil, nil})
        build.docker.packages.should be_empty
        build.docker.platform_flag?.should be_true
        build.docker.shards_install?.should be_true
        build.cross.linker.should eq("zig")
      end
    end
  end

  describe "the full documented schema" do
    it "parses every key and keeps its value" do
      Fixture.project(config: File.read("#{__DIR__}/../fixtures/full.crystalreleaser.yml")) do |project|
        project.write("shard.yml", "name: ssherlock\nversion: 1.0.0\ntargets:\n  ssherlock:\n    main: src/ssherlock.cr\n")
        config = load(project)

        config.version.should eq(1)
        config.env.should eq(["CGO_LIKE=unused"])
        config.before.hooks.should eq(["shards install --production", "crystal spec"])

        build = config.builds.first
        build.main.should eq("src/ssherlock.cr")
        build.flags.should eq(["--release", "--no-debug"])
        build.env.should eq(["SSHERLOCK_VERSION={{ .Version }}", "SSHERLOCK_COMMIT={{ .ShortCommit }}"])
        build.platforms.map { |platform| {platform.os, platform.arch, platform.strategy, platform.static?} }.should eq([
          {"linux", "amd64", "docker", true},
          {"linux", "arm64", "docker", true},
          {"darwin", "arm64", "native", false},
        ])
        build.cross.sysroot.should eq("/opt/sysroots/{{ .Os }}-{{ .Arch }}")

        archive = config.archives.first
        archive.format_overrides.first.os.should eq("windows")
        archive.format_overrides.first.formats.should eq(["zip"])
        archive.wrap_in_directory?.should be_false
        archive.file_specs.map { |file| {file.src, file.dst} }.should eq([
          {"LICENSE", nil},
          {"README.md", nil},
          {"completions/*", "completions"},
        ])

        config.changelog.filters.exclude.should eq(["^docs:", "^test:", "^chore:", "Merge pull request"])
        config.changelog.groups.map { |group| {group.title, group.regexp} }.should eq([
          {"Features", %q(^feat(\(.+\))?!?:)},
          {"Bug fixes", %q(^fix(\(.+\))?!?:)},
          {"Others", nil},
        ])

        github = config.release.github.should_not be_nil
        {github.owner, github.name}.should eq({"jbox-web", "ssherlock"})
        config.release.replace_existing_artifacts?.should be_true
        config.release.name_template.should eq("v{{ .Version }}")

        nfpm = config.nfpms.first
        nfpm.formats.should eq(["deb", "rpm"])
        nfpm.maintainer.should eq("Nicolas Rodriguez <nico@example.com>")
        nfpm.contents.map { |content| {content.src, content.dst} }.should eq([{"LICENSE", "/usr/share/doc/ssherlock/LICENSE"}])
        signature = nfpm.rpm.signature.should_not be_nil
        signature.key.should eq("{{ .Env.RPM_SIGNING_KEY }}")
        signature.passphrase.should eq("{{ .Env.RPM_SIGNING_PASSPHRASE }}")

        brew = config.brews.first
        tap = brew.repository.should_not be_nil
        {tap.owner, tap.name, tap.branch}.should eq({"jbox-web", "homebrew-tap", "master"})
        tap.token.should eq("{{ .Env.HOMEBREW_TAP_TOKEN }}")
        brew.directory.should eq("Formula")
        brew.install.should eq(%(bin.install "ssherlock"\n))

        aqua = config.aqua.first
        aqua.repository.branch.should eq("main")
        aqua.path.should eq("pkgs/jbox-web/ssherlock/registry.yaml")
      end
    end
  end

  describe "file lookup" do
    it "prefers .crystalreleaser.yml, then .crystalreleaser.yaml, then crystalreleaser.yml" do
      Fixture.project do |project|
        project.write("crystalreleaser.yml", "project_name: third\n")
        load(project).project_name.should eq("third")
        project.write(".crystalreleaser.yaml", "project_name: second\n")
        load(project).project_name.should eq("second")
        project.write(".crystalreleaser.yml", "project_name: first\n")
        load(project).project_name.should eq("first")
      end
    end

    it "uses the file given explicitly" do
      Fixture.project(config: "project_name: default\n") do |project|
        project.write("ci/release.yml", "project_name: explicit\n")
        load(project, "ci/release.yml").project_name.should eq("explicit")
      end
    end

    it "fails when the explicit file does not exist" do
      Fixture.project do |project|
        config_error(project, "nope.yml").should eq("config file not found: nope.yml")
      end
    end
  end

  describe "errors" do
    it "names an unknown key, the file and the line" do
      Fixture.project(config: "project_name: toy\nbiulds: []\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:2:1: unknown key 'biulds'")
      end
    end

    it "names a value of the wrong type" do
      Fixture.project(config: "builds: yes\n") do |project|
        config_error(project).should start_with(".crystalreleaser.yml:1:")
      end
    end

    it "reads static_libs as a list of formulas, in the order they are written, and as empty by default" do
      Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n    static_libs:\n" \
                              "      - formula: openssl@4\n        libs: [ssl, crypto]\n" \
                              "      - formula: libssh2\n        libs: [ssh2]\n") do |project|
        load(project).builds.first.static_libs.map { |entry| {entry.formula, entry.libs} }.should eq([
          {"openssl@4", ["ssl", "crypto"]},
          {"libssh2", ["ssh2"]},
        ])
      end
      Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n") do |project|
        load(project).builds.first.static_libs.should be_empty
      end
    end

    # Up to 0.2.1 static_libs was a single mapping: say what to write instead
    # of YAML's "expected a sequence".
    it "refuses static_libs written as a single mapping, and says it is a list" do
      Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n    static_libs:\n      formula: openssl@4\n      libs: [ssl]\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:4:5: static_libs is a list, one entry per Homebrew formula: " \
                                        "write `- formula: openssl@4` with its `libs:` under it")
      end
    end

    it "names what YAML found in words, not as a Crystal type" do
      Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n    static_libs:\n      - openssl@4\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:5:9: Expected mapping, not scalar")
      end
    end

    it "names a missing key" do
      Fixture.project(config: "aqua:\n  - repository:\n      owner: o\n      name: r\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:2:5: missing key 'path'")
      end
    end

    it "names what is wrong inside an optional section, not a Crystal type" do
      Fixture.project(config: "release:\n  github:\n    owner: o\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:3:5: missing key 'name'")
      end
      Fixture.project(config: "archives:\n  - files:\n      - source: x\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:3:9: unknown key 'source'")
      end
    end

    it "refuses a key written twice, whose first value would be dropped" do
      Fixture.project(config: "builds:\n  - id: a\n    target: toy\nbuilds:\n  - id: b\n    target: toy\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml:4:1: duplicate key 'builds'")
      end
    end

    it "refuses a second YAML document, which would be ignored" do
      Fixture.project(config: "project_name: a\n---\nproject_name: b\n") do |project|
        config_error(project).should eq(".crystalreleaser.yml: only one YAML document is allowed")
      end
    end

    it "still accepts anchors and merge keys" do
      Fixture.project(config: "builds:\n  - id: a\n    target: toy\n    platforms:\n      - &p\n        os: linux\n        arch: amd64\n      - <<: *p\n        arch: arm64\n") do |project|
        load(project).builds.first.platforms.map(&.arch).should eq(["amd64", "arm64"])
      end
    end

    it "reports a shard.yml target that is not a mapping" do
      Fixture.project(shard: "name: toy\ntargets:\n  toy: src/toy.cr\n") do |project|
        config_error(project).should eq("shard.yml: targets.toy: expected a mapping with a 'main' key")
      end
    end

    it "reads a version or a name that YAML takes for a number" do
      Fixture.project(shard: "name: 123\nversion: 1.0\ncrystal: 1.20\n") do |project|
        config = load(project)
        {config.project_name, config.shard_version, config.shard_crystal}.should eq({"123", "1.0", "1.20"})
      end
    end

    it "reports targets that are not a mapping, instead of building nothing" do
      Fixture.project(shard: "name: toy\ntargets: [toy]\n") do |project|
        config_error(project).should eq("shard.yml: targets: expected a mapping of target names")
      end
    end

    it "refuses a key written twice" do
      Fixture.project(shard: "name: toy\nname: other\n") do |project|
        config_error(project).should eq("shard.yml: duplicate key 'name'")
      end
    end

    it "says it cannot read shard.yml, without a backtrace" do
      pending!("root reads every file") if LibC.getuid == 0
      Fixture.project do |project|
        File.chmod(project.path("shard.yml"), 0o000)
        begin
          config_error(project).should start_with("cannot read shard.yml: ")
        ensure
          File.chmod(project.path("shard.yml"), 0o644)
        end
      end
    end

    it "fails without shard.yml" do
      Fixture.project do |project|
        File.delete(project.path("shard.yml"))
        config_error(project).should eq("shard.yml not found in #{project.dir}")
      end
    end

    it "fails on a shard.yml without name" do
      Fixture.project(shard: "version: 1.0.0\n") do |project|
        config_error(project).should eq("shard.yml: missing 'name'")
      end
    end
  end
end
