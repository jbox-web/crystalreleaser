require "../../spec_helper"

private CONFIG = <<-YAML
  release:
    github:
      owner: jbox-web
      name: toy
  aqua:
    - repository:
        owner: jbox-web
        name: aqua-registry
        branch: main
        token: "{{ .Env.AQUA_REGISTRY_TOKEN }}"
      path: pkgs/jbox-web/toy/registry.yaml
      description: A toy
  YAML

private def add(ctx, type, name : String, os : String? = nil, arch : String? = nil, wrap = "") : Nil
  ctx.artifacts.add(Crystalreleaser::Artifact.new(type, name, "dist/#{name}", os: os, arch: arch,
    extra: {"format" => "tar.gz", "binaries" => "toy", "wrap" => wrap}))
end

private def aqua_context(project, platforms, options = Crystalreleaser::Options.new, wrap = false)
  ctx = spec_context(project, options: options, env: {"AQUA_REGISTRY_TOKEN" => "aqua-secret"})
  Dir.mkdir_p(ctx.dist_path)
  platforms.each do |(os, arch)|
    base = "toy_1.2.3-rc.1_#{os}_#{arch}"
    add(ctx, Crystalreleaser::Artifact::Type::Archive, "#{base}.tar.gz", os, arch, wrap ? base : "")
  end
  add(ctx, Crystalreleaser::Artifact::Type::Checksum, "checksums.txt")
  ctx
end

private ALL = [{"linux", "amd64"}, {"linux", "arm64"}, {"darwin", "amd64"}, {"darwin", "arm64"}]

describe Crystalreleaser::Pipes::Aqua do
  it "only templates the os and arch of the name, not the same words in the project name" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project, env: {"AQUA_REGISTRY_TOKEN" => "aqua-secret"})
      Dir.mkdir_p(ctx.dist_path)
      [{"linux", "amd64"}, {"darwin", "arm64"}].each do |(os, arch)|
        add(ctx, Crystalreleaser::Artifact::Type::Archive, "linux-arm64-tool_1.2.3-rc.1_#{os}_#{arch}.tar.gz", os, arch)
      end
      Crystalreleaser::Pipes::Aqua.new.run(ctx)

      YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]["asset"]
        .should eq("linux-arm64-tool_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz")
    end
  end

  it "does not push a pre-release with skip_upload: auto" do
    Fixture.project(config: CONFIG + "\n    skip_upload: auto\n") do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new { github_response(500) }
      ctx = aqua_context(project, ALL, options)
      ctx.github_client_factory = ->(token : String) {
        Crystalreleaser::Github::Client.new(token, transport, ->(_span : Time::Span) { nil }).as(Crystalreleaser::Github::Client)
      }
      Crystalreleaser::Pipes::Aqua.new.run(ctx)
      Crystalreleaser::Pipes::AquaPush.new.run(ctx)
      transport.requests.should be_empty
      File.exists?(project.path("dist/aqua/registry.yaml")).should be_true
    end
  end

  it "does not push while the release is a draft" do
    Fixture.project(config: CONFIG.sub("release:\n", "release:\n  draft: true\n")) do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new { github_response(500) }
      ctx = aqua_context(project, ALL, options)
      ctx.github_client_factory = ->(token : String) {
        Crystalreleaser::Github::Client.new(token, transport, ->(_span : Time::Span) { nil }).as(Crystalreleaser::Github::Client)
      }
      Crystalreleaser::Pipes::Aqua.new.run(ctx)
      Crystalreleaser::Pipes::AquaPush.new.run(ctx)
      transport.requests.should be_empty
      File.exists?(project.path("dist/aqua/registry.yaml")).should be_true
    end
  end

  it "derives the asset template and the environments from the archives" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))

      YAML.parse(File.read(project.path("dist/aqua/registry.yaml"))).should eq(YAML.parse(<<-YAML))
        packages:
          - type: github_release
            repo_owner: jbox-web
            repo_name: toy
            description: A toy
            version_constraint: "true"
            asset: "toy_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz"
            format: tar.gz
            files:
              - name: toy
            supported_envs: [darwin, linux]
            checksum:
              type: github_release
              asset: checksums.txt
              algorithm: sha256
        YAML
    end
  end

  # A bare `true`, `null`, `123` or `yes` is read back as a boolean, nothing,
  # a number: every value here is text.
  {"true", "null", "123", "yes", "~", "1.5"}.each do |word|
    it "writes the description #{word} as text" do
      Fixture.project(config: CONFIG.sub("description: A toy", "description: #{word.inspect}")) do |project|
        Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))
        text = File.read(project.path("dist/aqua/registry.yaml"))
        text.should contain(%(description: "#{word}"\n))
        YAML.parse(text)["packages"][0]["description"].as_s?.should eq(word)
      end
    end
  end

  it "leaves ordinary text unquoted" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))
      File.read(project.path("dist/aqua/registry.yaml")).should contain("description: A toy\n")
    end
  end

  # A bare binary published next to the archives is another asset of the
  # same platform, under another name: the entry describes the archives.
  it "describes the tar.gz archives and leaves the bare binaries out" do
    Fixture.project(config: CONFIG) do |project|
      ctx = aqua_context(project, ALL)
      ALL.each do |(os, arch)|
        ctx.artifacts.add(Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Archive, "toy-#{os}-#{arch}",
          "dist/toy-#{os}-#{arch}", os: os, arch: arch, extra: {"format" => "binary", "binaries" => "toy", "wrap" => ""}))
      end
      Crystalreleaser::Pipes::Aqua.new.run(ctx)

      package = YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]
      {package["asset"], package["format"]}.should eq({"toy_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz", "tar.gz"})
    end
  end

  it "points at the checksum file of each asset when the checksums are split" do
    Fixture.project(config: CONFIG + "\nchecksum:\n  split: true\n") do |project|
      ctx = spec_context(project, env: {"AQUA_REGISTRY_TOKEN" => "aqua-secret"})
      Dir.mkdir_p(ctx.dist_path)
      ALL.each do |(os, arch)|
        name = "toy_1.2.3-rc.1_#{os}_#{arch}.tar.gz"
        add(ctx, Crystalreleaser::Artifact::Type::Archive, name, os, arch)
        add(ctx, Crystalreleaser::Artifact::Type::Checksum, "#{name}.sha256")
      end
      Crystalreleaser::Pipes::Aqua.new.run(ctx)

      YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]["checksum"].should eq(YAML.parse(<<-YAML))
        type: github_release
        asset: "{{.Asset}}.sha256"
        algorithm: sha256
        YAML
    end
  end

  # The jbox-web registry, like aqua's own, concatenates the entries of every
  # pkgs/*/registry.yaml under one `packages:` key (scripts/build-registry.sh):
  # an entry must be written the way the others are, its list indented under
  # `packages:`, or the concatenation is no longer valid YAML.
  it "writes the entry the way aqua registries do: schema comment, list indented under packages" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))
      File.read(project.path("dist/aqua/registry.yaml")).should eq(<<-YAML)
        # yaml-language-server: $schema=https://raw.githubusercontent.com/aquaproj/aqua/main/json-schema/registry.json
        packages:
          - type: github_release
            repo_owner: jbox-web
            repo_name: toy
            description: A toy
            version_constraint: "true"
            asset: "toy_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz"
            format: tar.gz
            files:
              - name: toy
            supported_envs:
              - darwin
              - linux
            checksum:
              type: github_release
              asset: checksums.txt
              algorithm: sha256

        YAML
    end
  end

  it "concatenates with an entry written by hand into one valid registry" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))
      ours = File.read(project.path("dist/aqua/registry.yaml"))
      by_hand = "packages:\n  - type: github_release\n    repo_owner: jbox-web\n    repo_name: other\n"
      # What build-registry.sh does: every entry after its own `packages:` line.
      merged = "packages:\n" + [by_hand, ours].join(&.split("packages:\n", 2).last)
      YAML.parse(merged)["packages"].as_a.map(&.["repo_name"].as_s).should eq(["other", "toy"])
    end
  end

  it "keeps version_constraint a string, not a boolean" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL))
      text = File.read(project.path("dist/aqua/registry.yaml"))
      YAML.parse(text)["packages"][0]["version_constraint"].as_s.should eq("true")
      text.should contain("{{trimV .Version}}")
    end
  end

  it "lists os/arch pairs when an os is not fully covered" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, [{"linux", "amd64"}, {"linux", "arm64"}, {"darwin", "arm64"}]))
      YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]["supported_envs"]
        .should eq(YAML.parse("[darwin/arm64, linux]"))
    end
  end

  it "points files inside the wrapping directory" do
    Fixture.project(config: CONFIG) do |project|
      Crystalreleaser::Pipes::Aqua.new.run(aqua_context(project, ALL, wrap: true))
      YAML.parse(File.read(project.path("dist/aqua/registry.yaml")))["packages"][0]["files"]
        .should eq(YAML.parse(%([{name: toy, src: "toy_{{trimV .Version}}_{{.OS}}_{{.Arch}}/toy"}])))
    end
  end

  it "pushes the registry entry when publishing" do
    Fixture.project(config: CONFIG) do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new { |request| request.method == "GET" ? github_response(404) : github_response(201) }
      ctx = aqua_context(project, ALL, options)
      ctx.github_client_factory = ->(token : String) {
        Crystalreleaser::Github::Client.new(token, transport, ->(_span : Time::Span) { nil }).as(Crystalreleaser::Github::Client)
      }
      Crystalreleaser::Pipes::Aqua.new.run(ctx)
      transport.requests.should be_empty
      Crystalreleaser::Pipes::AquaPush.new.run(ctx)

      transport.calls.should eq([
        "GET https://api.github.com/repos/jbox-web/aqua-registry/contents/pkgs/jbox-web/toy/registry.yaml?ref=main",
        "PUT https://api.github.com/repos/jbox-web/aqua-registry/contents/pkgs/jbox-web/toy/registry.yaml",
      ])
      put = transport.requests.last
      put.headers["Authorization"].should eq("Bearer aqua-secret")
      body = JSON.parse(put.body)
      {body["message"], body["branch"], body["sha"]?}.should eq({"Aqua registry update for toy version v1.2.3-rc.1", "main", nil})
    end
  end

  it "refuses archive names that share no single template" do
    Fixture.project(config: CONFIG) do |project|
      ctx = aqua_context(project, [{"linux", "amd64"}])
      add(ctx, Crystalreleaser::Artifact::Type::Archive, "other-darwin-arm64.tar.gz", "darwin", "arm64")
      expect_raises(Crystalreleaser::PackageError, "aqua: the archive names do not follow one template: " \
                                                   "toy_{{trimV .Version}}_{{.OS}}_{{.Arch}}.tar.gz, other-{{.OS}}-{{.Arch}}.tar.gz") do
        Crystalreleaser::Pipes::Aqua.new.run(ctx)
      end
    end
  end
end
