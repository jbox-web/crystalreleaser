require "../spec_helper"

private LINUX_HOST  = Crystalreleaser::Host.new("linux", "amd64", musl: false)
private DARWIN_HOST = Crystalreleaser::Host.new("darwin", "arm64", musl: false)

private def validate(config_yaml : String, host = LINUX_HOST) : Crystalreleaser::Validator::Result
  result = Crystalreleaser::Validator::Result.new([] of String, [] of String)
  Fixture.project(config: config_yaml) do |project|
    config = Crystalreleaser::Config.load(project.dir, nil, host)
    result = Crystalreleaser::Validator.new(config, host).run
  end
  result
end

private def errors(config_yaml : String, host = LINUX_HOST) : Array(String)
  validate(config_yaml, host).errors
end

private def warnings(config_yaml : String, host = LINUX_HOST) : Array(String)
  validate(config_yaml, host).warnings
end

private def build_with(platforms : String, extra : String = "") : String
  <<-YAML
    builds:
      - id: toy
        target: toy
    #{extra}
        platforms:
    #{platforms}
    YAML
end

describe Crystalreleaser::Validator do
  describe "what would only fail later" do
    it "rejects a project with nothing to build" do
      result = Crystalreleaser::Validator::Result.new([] of String, [] of String)
      Fixture.project(shard: "name: lib\nversion: 1.0.0\n") do |project|
        config = Crystalreleaser::Config.load(project.dir, nil, LINUX_HOST)
        result = Crystalreleaser::Validator.new(config, LINUX_HOST).run
      end
      result.errors.should eq(["builds: nothing to build: shard.yml declares no target and no build is configured"])
    end

    it "rejects an unknown cross linker" do
      errors(build_with("      - os: linux\n        arch: amd64\n", "    cross:\n      linker: clang\n"))
        .should eq(["builds[0].cross.linker: unknown linker 'clang' (expected zig or cc)"])
    end

    it "rejects an empty list of formats" do
      errors("archives:\n  - id: a\n    formats: []\n").should eq(["archives[0].formats: at least one format is required"])
      errors("nfpms:\n  - maintainer: J <j@example.com>\n    formats: []\n")
        .should eq(["nfpms[0].formats: at least one format is required"])
    end

    it "accepts the binary format, alone, with others and in an override" do
      errors("archives:\n  - id: a\n    formats: [binary]\n").should be_empty
      errors("archives:\n  - id: a\n    formats: [tar.gz, binary]\n    format_overrides:\n      - os: darwin\n        formats: [binary]\n")
        .should be_empty
    end

    it "rejects a format override for an unknown os" do
      errors("archives:\n  - id: a\n    format_overrides:\n      - os: plan9\n        formats: [zip]\n")
        .should eq(["archives[0].format_overrides[0].os: unknown os 'plan9' (expected linux, darwin, freebsd or windows)"])
    end

    it "rejects an empty release repository" do
      errors("release:\n  github:\n    owner: \"\"\n    name: toy\n")
        .should eq(["release.github: owner and name must not be empty"])
    end

    it "rejects names that are used as file names and hold a slash" do
      errors("project_name: a/b\nbuilds:\n  - id: x/y\n    target: toy\n    binary: ../toy\n").should eq([
        %(project_name: "a/b" is not a plain name),
        %(builds[0].id: "x/y" is not a plain name),
        %(builds[0].binary: "../toy" is not a plain name),
      ])
    end

    it "rejects a static native build on a glibc host, which cannot link it" do
      errors(build_with("      - os: linux\n        arch: amd64\n        static: true\n"))
        .should eq(["builds[0].platforms[0]: a static native build needs a musl host (e.g. Alpine); use strategy: docker"])
      musl = Crystalreleaser::Host.new("linux", "amd64", musl: true)
      errors(build_with("      - os: linux\n        arch: amd64\n        static: true\n"), musl).should be_empty
    end

    # The name becomes dist/homebrew/<name>.rb, the path in the tap and the
    # Ruby class of the formula.
    {"jbox-web/tap/toy", "../../../x", "to\"y", "to y", "-toy"}.each do |name|
      it "rejects the formula name #{name.inspect}" do
        errors("project_name: toy\nbrews:\n  - name: #{name.inspect}\n")
          .should eq(["brews[0].name: #{name.inspect} is not a formula name (letters, digits and + - _ . @)"])
      end
    end

    it "accepts the formula names Homebrew itself uses" do
      errors("brews:\n  - name: toy\n  - name: node@20\n  - name: gtk+3\n  - name: foo-bar_baz.1\n").should be_empty
    end

    {"../Formula", "/Formula", "Formula/../..", "Formula//x"}.each do |directory|
      it "rejects the tap directory #{directory.inspect}" do
        errors("brews:\n  - name: toy\n    directory: #{directory.inspect}\n")
          .should eq(["brews[0].directory: must be a relative path without '..' or '//', got #{directory.inspect}"])
      end
    end

    it "rejects a registry path that leaves the registry" do
      errors("aqua:\n  - path: ../registry.yaml\n    repository:\n      owner: jbox-web\n      name: aqua-registry\n")
        .should eq(["aqua[0].path: must be a relative path without '..' or '//', got \"../registry.yaml\""])
    end

    it "accepts a nested tap directory" do
      errors("brews:\n  - name: toy\n    directory: Formula/t\n").should be_empty
    end

    {"../../x", "/etc", "a/../../b"}.each do |dst|
      it "rejects the archive destination #{dst.inspect}" do
        errors("archives:\n  - id: a\n    files:\n      - src: LICENSE\n        dst: #{dst.inspect}\n")
          .should eq(["archives[0].files[0].dst: must be a relative path without '..' or '//', got #{dst.inspect}"])
      end
    end

    it "accepts an archive destination inside the archive" do
      errors("archives:\n  - id: a\n    files:\n      - src: LICENSE\n        dst: share/doc\n").should be_empty
    end

    {"Foo Bar/..", "foo/bar", " ", "-foo"}.each do |name|
      it "rejects the package name #{name.inspect}" do
        errors("nfpms:\n  - maintainer: J <j@example.com>\n    package_name: #{name.inspect}\n")
          .should eq(["nfpms[0].package_name: #{name.inspect} is not a package name (letters, digits and + - _ .)"])
      end
    end

    it "rejects a release repository that is not an owner and a name" do
      errors("release:\n  github:\n    owner: a/b\n    name: toy\n")
        .should eq(["release.github.owner: \"a/b\" is not a GitHub owner or repository name"])
      errors("release:\n  github:\n    owner: jbox-web\n    name: \"toy?x=1\"\n")
        .should eq(["release.github.name: \"toy?x=1\" is not a GitHub owner or repository name"])
    end

    it "rejects a tap and a registry that are not an owner and a name" do
      errors("brews:\n  - name: toy\n    repository:\n      owner: a/b\n      name: homebrew-tap\n")
        .should eq(["brews[0].repository.owner: \"a/b\" is not a GitHub owner or repository name"])
      errors("aqua:\n  - path: pkgs/toy/registry.yaml\n    repository:\n      owner: jbox-web\n      name: \"a b\"\n")
        .should eq(["aqua[0].repository.name: \"a b\" is not a GitHub owner or repository name"])
    end

    it "rejects an environment variable name a shell could not export" do
      errors("env:\n  - \"A B=1\"\n").should eq(["env[0]: \"A B\" is not an environment variable name"])
      errors(build_with("      - os: linux\n        arch: amd64\n", "    env:\n      - \"1X=1\"\n"))
        .should eq(["builds[0].env[0]: \"1X\" is not an environment variable name"])
    end

    it "rejects a blank build id" do
      errors("builds:\n  - id: \" \"\n    target: toy\n").should eq(["builds[0].id: \" \" is not a plain name"])
    end

    describe "docker.dockerfile" do
      docker = "      - os: linux\n        arch: amd64\n        strategy: docker\n        static: true\n"

      it "accepts a Dockerfile of the project, with or without a target" do
        errors(build_with(docker, "    docker:\n      dockerfile: Dockerfile\n")).should be_empty
        errors(build_with(docker, "    docker:\n      dockerfile: build/Dockerfile\n      target: toolchain\n")).should be_empty
      end

      it "rejects an image and a Dockerfile together: only one can be the build image" do
        errors(build_with(docker, "    docker:\n      image: alpine:3.24\n      dockerfile: Dockerfile\n"))
          .should eq(["builds[0].docker: set image or dockerfile, not both"])
      end

      it "rejects the settings of the generated image next to an image or a Dockerfile" do
        errors(build_with(docker, "    docker:\n      dockerfile: Dockerfile\n      alpine: \"3.24\"\n"))
          .should eq(["builds[0].docker: alpine and packages only apply to the generated image, not with dockerfile"])
        errors(build_with(docker, "    docker:\n      image: my/crystal\n      packages: [gmp-static]\n"))
          .should eq(["builds[0].docker: alpine and packages only apply to the generated image, not with image"])
      end

      it "rejects an Alpine release or a package name apk would not take" do
        errors(build_with(docker, "    docker:\n      alpine: latest\n      packages: [\"gmp static\"]\n")).should eq([
          %(builds[0].docker.alpine: "latest" is not an Alpine release (e.g. 3.24)),
          %(builds[0].docker.packages[0]: "gmp static" is not an apk package name),
        ])
      end

      it "rejects a target without a Dockerfile" do
        errors(build_with(docker, "    docker:\n      target: toolchain\n"))
          .should eq(["builds[0].docker.target: only used with docker.dockerfile"])
      end

      it "rejects a Dockerfile outside the project" do
        errors(build_with(docker, "    docker:\n      dockerfile: ../Dockerfile\n"))
          .should eq(["builds[0].docker.dockerfile: must be a relative path without '..' or '//', got \"../Dockerfile\""])
      end

      # Its base is not known before it is built.
      it "does not guess whether the image of a Dockerfile is an Alpine one" do
        warnings(build_with("      - os: linux\n        arch: amd64\n        strategy: docker\n", "    docker:\n      dockerfile: Dockerfile\n"))
          .should be_empty
      end
    end

    it "rejects an empty docker image for a docker build" do
      errors(build_with("      - os: linux\n        arch: amd64\n        strategy: docker\n        static: true\n",
        "    docker:\n      image: \"\"\n")).should eq(["builds[0].docker.image: must not be empty"])
    end

    # The default image is an Alpine one: without --static, the binary needs
    # the musl loader, which no glibc distribution has, while it is labelled
    # and packaged as an ordinary linux binary.
    it "warns about a docker build in an Alpine image that is not static" do
      warnings(build_with("      - os: linux\n        arch: amd64\n        strategy: docker\n")).should eq([
        "builds[0].platforms[0]: a docker build in an Alpine image without static: true is linked dynamically " \
        "against musl, and only runs on a musl system",
      ])
    end

    it "does not warn about a static docker build, nor about one in another image" do
      warnings(build_with("      - os: linux\n        arch: amd64\n        strategy: docker\n        static: true\n")).should be_empty
      warnings(build_with("      - os: linux\n        arch: amd64\n        strategy: docker\n",
        "    docker:\n      image: 84codes/crystal:1.20.3-ubuntu-24.04\n")).should be_empty
    end

    it "rejects an unknown type of package content" do
      errors("nfpms:\n  - maintainer: J <j@example.com>\n    contents:\n      - src: a.conf\n        dst: /etc/a.conf\n        type: conf\n")
        .should eq(["nfpms[0].contents[0].type: unknown type 'conf' (expected config or config|noreplace)"])
      errors("nfpms:\n  - maintainer: J <j@example.com>\n    contents:\n      - src: a.conf\n        dst: /etc/a.conf\n        type: config\n")
        .should be_empty
    end

    it "rejects an unknown make_latest" do
      errors("release:\n  make_latest: maybe\n")
        .should eq(["release.make_latest: unknown value 'maybe' (expected true, false or legacy)"])
      {"true", "false", "legacy"}.each do |value|
        errors("release:\n  make_latest: #{value}\n").should be_empty
      end
    end

    it "rejects an unknown skip_upload" do
      errors("brews:\n  - name: toy\n    skip_upload: maybe\n")
        .should eq(["brews[0].skip_upload: unknown value 'maybe' (expected auto, true or false)"])
      errors("aqua:\n  - path: registry.yaml\n    skip_upload: maybe\n    repository:\n      owner: o\n      name: r\n")
        .should eq(["aqua[0].skip_upload: unknown value 'maybe' (expected auto, true or false)"])
      errors("brews:\n  - name: toy\n    skip_upload: true\n").should be_empty
    end

    it "rejects two aqua entries writing the same file" do
      entry = "  - path: registry.yaml\n    repository:\n      owner: o\n      name: r\n"
      errors("aqua:\n#{entry}#{entry}").should eq(["aqua: duplicate path 'registry.yaml' in o/r"])
    end
  end

  describe "package paths" do
    nfpm = "nfpms:\n  - maintainer: Jane <j@example.com>\n"

    it "accepts absolute, normalized paths" do
      errors("#{nfpm}    bindir: /usr/local/bin\n    contents:\n      - src: LICENSE\n        dst: /usr/share/doc/toy/LICENSE\n")
        .should be_empty
    end

    it "rejects a relative bindir" do
      errors("#{nfpm}    bindir: usr/bin\n")
        .should eq([%(nfpms[0].bindir: must be an absolute path without '..' or '//', got "usr/bin")])
    end

    {"etc/toy/LICENSE", "/opt/../etc/passwd", "/usr//share/x", "/usr/share/"}.each do |dst|
      it "rejects the content destination #{dst}" do
        errors("#{nfpm}    contents:\n      - src: LICENSE\n        dst: #{dst}\n")
          .should eq(["nfpms[0].contents[0].dst: must be an absolute path without '..' or '//', got #{dst.inspect}"])
      end
    end
  end

  describe "dist" do
    {".git", ".git/dist", "./.git"}.each do |value|
      it "rejects dist: #{value.inspect}, the repository itself" do
        errors("dist: #{value.inspect}\n").should eq(["dist: must not be the .git directory or inside it, got #{value.inspect}"])
      end
    end

    it "accepts a directory inside the project" do
      errors("dist: build/out\n").should be_empty
    end

    {".", "", "..", "../out", "a/..", "/tmp/out", "./"}.each do |value|
      it "rejects dist: #{value.inspect}, which --clean would delete" do
        errors("dist: #{value.inspect}\n")
          .should eq(["dist: must be a directory inside the project, got #{value.inspect}"])
      end
    end
  end

  it "accepts the defaults derived from shard.yml" do
    result = validate("")
    result.errors.should be_empty
    result.warnings.should be_empty
  end

  it "accepts the full documented schema on a darwin/arm64 host" do
    Fixture.project(config: File.read("#{__DIR__}/../fixtures/full.crystalreleaser.yml")) do |project|
      project.write("shard.yml", "name: ssherlock\nversion: 1.0.0\ntargets:\n  ssherlock:\n    main: src/ssherlock.cr\n")
      config = Crystalreleaser::Config.load(project.dir, nil, DARWIN_HOST)
      result = Crystalreleaser::Validator.new(config, DARWIN_HOST).run
      result.errors.should be_empty
      result.warnings.should be_empty
    end
  end

  # The example at the root of the repository is what users copy: it must
  # stay a configuration crystalreleaser accepts as it is.
  it "accepts .crystalreleaser.example.yml, with only the warning of the platform this host cannot build" do
    Fixture.project(config: File.read("#{__DIR__}/../../.crystalreleaser.example.yml")) do |project|
      project.write("shard.yml", "name: myapp\nversion: 1.0.0\ntargets:\n  myapp:\n    main: src/myapp.cr\n")
      config = Crystalreleaser::Config.load(project.dir, nil, DARWIN_HOST)
      result = Crystalreleaser::Validator.new(config, DARWIN_HOST).run
      result.errors.should be_empty
      result.warnings.should eq(["builds[0].platforms[3]: native build of darwin/amd64 on a darwin/arm64 host will be skipped"])
      config.builds.first.docker.packages.should eq(["libxml2-dev", "libxml2-static", "gmp-dev", "gmp-static"])
      config.archives.map(&.formats).should eq([["tar.gz"], ["binary"]])
    end
  end

  describe "ids and references" do
    it "rejects duplicate build ids" do
      errors("builds:\n  - id: toy\n    target: toy\n  - id: toy\n    target: toy\n")
        .should eq(["builds: duplicate id 'toy'"])
    end

    it "rejects an archive pointing to an unknown build" do
      errors("archives:\n  - id: a\n    builds: [nope]\n")
        .should eq(["archives[0].builds: unknown build 'nope'"])
    end

    it "rejects duplicate archive ids" do
      errors("archives:\n  - id: a\n  - id: a\n").should eq(["archives: duplicate id 'a'"])
    end

    it "rejects an nfpm pointing to an unknown build" do
      errors("nfpms:\n  - id: p\n    maintainer: m\n    builds: [nope]\n")
        .should eq(["nfpms[0].builds: unknown build 'nope'"])
    end

    it "rejects duplicate brew names" do
      errors("brews:\n  - name: x\n  - name: x\n").should eq(["brews: duplicate name 'x'"])
    end
  end

  describe "builds" do
    it "rejects a target absent from shard.yml" do
      errors("builds:\n  - id: b\n    target: nope\n")
        .should eq(["builds[0].target: no target 'nope' in shard.yml"])
    end

    it "requires a target or a main" do
      errors("builds:\n  - id: b\n").should eq(["builds[0]: set either target or main"])
    end

    it "rejects an unsupported os/arch couple" do
      errors(build_with("      - os: solaris\n        arch: amd64\n")).should eq([
        "builds[0].platforms[0]: unsupported platform solaris/amd64 " \
        "(supported: linux/amd64, linux/arm64, darwin/amd64, darwin/arm64, freebsd/amd64)",
      ])
    end

    it "accepts windows with a warning" do
      result = validate(build_with("      - os: windows\n        arch: amd64\n        strategy: cross\n", "    cross:\n      sysroot: /s\n"))
      result.errors.should be_empty
      result.warnings.should eq(["builds[0].platforms[0]: windows/amd64 is accepted but cannot be built yet; it will be skipped"])
    end

    it "warns, without failing, about a native build for another platform" do
      result = validate(build_with("      - os: darwin\n        arch: arm64\n        strategy: native\n"))
      result.errors.should be_empty
      result.warnings.should eq(["builds[0].platforms[0]: native build of darwin/arm64 on a linux/amd64 host will be skipped"])
    end

    it "rejects an unknown strategy" do
      errors(build_with("      - os: linux\n        arch: amd64\n        strategy: magic\n"))
        .should eq(["builds[0].platforms[0].strategy: unknown strategy 'magic' (expected docker, cross or native)"])
    end

    it "rejects a duplicate platform" do
      errors(build_with("      - os: linux\n        arch: amd64\n      - os: linux\n        arch: amd64\n"))
        .should eq(["builds[0].platforms[1]: duplicate platform linux/amd64"])
    end

    it "rejects the docker strategy for a non-linux platform" do
      errors(build_with("      - os: darwin\n        arch: arm64\n        strategy: docker\n"))
        .should eq(["builds[0].platforms[0]: the docker strategy only builds linux binaries"])
    end

    it "rejects static linking on darwin" do
      errors(build_with("      - os: darwin\n        arch: arm64\n        static: true\n"), DARWIN_HOST)
        .should eq(["builds[0].platforms[0]: static linking is not supported on darwin"])
    end

    it "requires a sysroot for the cross strategy" do
      errors(build_with("      - os: linux\n        arch: arm64\n        strategy: cross\n"))
        .should eq(["builds[0].cross.sysroot: required by the cross strategy"])
    end
  end

  describe "formats and enumerations" do
    it "rejects an unknown archive format" do
      errors("archives:\n  - id: a\n    formats: [rar]\n")
        .should eq(["archives[0].formats: unknown format 'rar' (expected tar.gz, zip or binary)"])
    end

    it "requires a package maintainer" do
      errors("nfpms:\n  - id: p\n").should eq(["nfpms[0].maintainer: required by the deb and rpm formats"])
    end

    it "rejects an unknown package format" do
      errors("nfpms:\n  - id: p\n    maintainer: m\n    formats: [apk]\n")
        .should eq(["nfpms[0].formats: unknown format 'apk' (expected deb or rpm)"])
    end

    it "rejects a checksum algorithm other than sha256" do
      errors("checksum:\n  algorithm: md5\n")
        .should eq(["checksum.algorithm: unsupported algorithm 'md5' (expected sha256)"])
    end

    it "rejects the github changelog source for now" do
      errors("changelog:\n  use: github\n")
        .should eq(["changelog.use: 'github' is not supported yet (expected git)"])
    end

    it "rejects an unknown changelog order" do
      errors("changelog:\n  sort: random\n")
        .should eq(["changelog.sort: unknown order 'random' (expected asc or desc)"])
    end

    it "rejects an invalid group regexp" do
      errors = errors("changelog:\n  groups:\n    - title: Bad\n      regexp: '('\n")
      errors.size.should eq(1)
      errors.first.should start_with("changelog.groups[0].regexp: invalid regular expression: ")
    end

    it "rejects a catch-all group that is not the last one" do
      errors("changelog:\n  groups:\n    - title: Others\n    - title: Features\n      regexp: '^feat'\n")
        .should eq(["changelog.groups[0]: only the last group may omit regexp"])
    end

    it "rejects an invalid exclude filter" do
      errors = errors("changelog:\n  filters:\n    exclude: ['[']\n")
      errors.size.should eq(1)
      errors.first.should start_with("changelog.filters.exclude[0]: invalid regular expression: ")
    end

    it "rejects an unknown prerelease value" do
      errors("release:\n  prerelease: maybe\n")
        .should eq(["release.prerelease: unknown value 'maybe' (expected auto, true or false)"])
    end

    it "rejects an env entry without '='" do
      errors("env:\n  - NOPE\n").should eq(["env[0]: expected KEY=VALUE, got 'NOPE'"])
    end

    it "rejects an unsupported config version" do
      errors("version: 2\n").should eq(["version: unsupported config version 2 (expected 1)"])
    end
  end

  describe "templates" do
    it "reports an unknown variable with its field" do
      errors("archives:\n  - id: a\n    name_template: '{{ .Nope }}'\n")
        .should eq(["archives[0].name_template: unknown variable .Nope"])
    end

    it "reports a variable that the field cannot provide" do
      errors("checksum:\n  name_template: '{{ .Os }}.txt'\n")
        .should eq(["checksum.name_template: variable .Os is not available here"])
    end

    it "accepts per-platform variables where a platform is known" do
      errors("builds:\n  - id: b\n    target: toy\n    env:\n      - X={{ .Os }}-{{ .Target }}-{{ .Binary }}\n")
        .should be_empty
    end

    it "does not require environment variables to be set at check time" do
      errors("brews:\n  - name: x\n    repository:\n      owner: o\n      name: n\n      token: '{{ .Env.UNSET_FOR_SURE }}'\n")
        .should be_empty
    end
  end

  describe "#run!" do
    it "raises every error at once" do
      Fixture.project(config: "version: 2\nenv: [NOPE]\n") do |project|
        config = Crystalreleaser::Config.load(project.dir, nil, LINUX_HOST)
        error = expect_raises(Crystalreleaser::ConfigError) do
          Crystalreleaser::Validator.new(config, LINUX_HOST).run!
        end
        error.message.should eq(
          "invalid configuration:\n" \
          "  - version: unsupported config version 2 (expected 1)\n" \
          "  - env[0]: expected KEY=VALUE, got 'NOPE'"
        )
      end
    end
  end
end
