require "../../spec_helper"

private CONFIG = <<-'YAML'
  release:
    github:
      owner: jbox-web
      name: toy
  brews:
    - name: toy
      repository:
        owner: jbox-web
        name: homebrew-tap
        branch: master
        token: "{{ .Env.HOMEBREW_TAP_TOKEN }}"
      directory: Formula
      homepage: https://example.com/toy
      description: 'A "toy" that prints #{name}'
      license: MIT
  YAML

private def add_archive(ctx, os : String, arch : String, sha256 : String, format = "tar.gz") : Nil
  name = "toy_1.2.3-rc.1_#{os}_#{arch}.#{format}"
  artifact = Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Archive, name, "dist/#{name}",
    os: os, arch: arch, extra: {"format" => format, "binaries" => "toy"})
  artifact.sha256 = sha256
  ctx.artifacts.add(artifact)
end

private def homebrew_context(project, options = Crystalreleaser::Options.new, transport : FakeTransport? = nil,
                             log : IO = IO::Memory.new)
  ctx = spec_context(project, options: options, env: {"HOMEBREW_TAP_TOKEN" => "tap-secret", "GITHUB_TOKEN" => "gh"}, log: log)
  if fake = transport
    ctx.github_client_factory = ->(token : String) {
      Crystalreleaser::Github::Client.new(token, fake, ->(_span : Time::Span) { nil }).as(Crystalreleaser::Github::Client)
    }
  end
  Dir.mkdir_p(ctx.dist_path)
  add_archive(ctx, "darwin", "arm64", "b49bb0bcf1e8a8de47c2a8d0a6f9d56d2e04a9f6a0d0d0e7d0f20b7a6e8c4a1e")
  add_archive(ctx, "linux", "amd64", "0" * 64)
  add_archive(ctx, "darwin", "amd64", "8d36a1a0b3e5b0ef8a3eda5bcbe02af6765f9e5d1f86f40dd65ab23fb6b4ddc4")
  add_archive(ctx, "windows", "amd64", "f" * 64, "zip")
  ctx
end

# Both halves, in the order of the pipeline: the formula is generated before
# the release is published, and pushed after.
private def generate_and_push(ctx : Crystalreleaser::Context) : Nil
  Crystalreleaser::Pipes::Homebrew.new.run(ctx)
  Crystalreleaser::Pipes::HomebrewPush.new.run(ctx)
end

describe Crystalreleaser::Pipes::Homebrew do
  describe ".class_name" do
    it "camel-cases the formula name as Homebrew does" do
      Crystalreleaser::Pipes::Homebrew.class_name("ssherlock").should eq("Ssherlock")
      Crystalreleaser::Pipes::Homebrew.class_name("foo-bar").should eq("FooBar")
      Crystalreleaser::Pipes::Homebrew.class_name("foo_bar.baz").should eq("FooBarBaz")
      Crystalreleaser::Pipes::Homebrew.class_name("node@20").should eq("NodeAT20")
    end
  end

  it "writes the formula to dist/homebrew/ with one block per platform built" do
    Fixture.project(config: CONFIG) do |project|
      ctx = homebrew_context(project)
      Crystalreleaser::Pipes::Homebrew.new.run(ctx)

      File.read(project.path("dist/homebrew/toy.rb"))
        .should eq(File.read("#{__DIR__}/../../fixtures/homebrew/toy.rb"))
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Formula).map(&.path).should eq(["dist/homebrew/toy.rb"])
    end
  end

  it "does not push in a snapshot or with --skip=publish" do
    {true, false}.each do |snapshot|
      Fixture.project(config: CONFIG) do |project|
        options = Crystalreleaser::Options.new
        options.publish = true
        options.skip = ["publish"] unless snapshot
        transport = FakeTransport.new { github_response(500) }
        ctx = homebrew_context(project, options, transport)
        ctx.version_info = Crystalreleaser::VersionInfo.snapshot("v1.2.2", "abc1234") if snapshot
        generate_and_push(ctx)

        transport.requests.should be_empty
        File.exists?(project.path("dist/homebrew/toy.rb")).should be_true
      end
    end
  end

  it "pushes the formula to the tap with the tap token" do
    Fixture.project(config: CONFIG) do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new do |request|
        request.method == "GET" ? github_response(200, %({"sha": "old"})) : github_response(200)
      end
      generate_and_push(homebrew_context(project, options, transport))

      transport.calls.should eq([
        "GET https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb?ref=master",
        "PUT https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb",
      ])
      put = transport.requests.last
      put.headers["Authorization"].should eq("Bearer tap-secret")
      body = JSON.parse(put.body)
      {body["message"], body["branch"], body["sha"]}
        .should eq({"Brew formula update for toy version v1.2.3-rc.1", "master", "old"})
      Base64.decode_string(body["content"].as_s).should eq(File.read(project.path("dist/homebrew/toy.rb")))
    end
  end

  # A formula installs from an archive: a bare binary of the same platform
  # is neither a second candidate nor a conflict.
  it "points at the tar.gz archives and leaves the bare binaries out" do
    Fixture.project(config: CONFIG) do |project|
      ctx = homebrew_context(project)
      add_archive(ctx, "linux", "amd64", "1" * 64, "binary")
      add_archive(ctx, "darwin", "arm64", "2" * 64, "binary")
      Crystalreleaser::Pipes::Homebrew.new.run(ctx)

      File.read(project.path("dist/homebrew/toy.rb")).should eq(File.read("#{__DIR__}/../../fixtures/homebrew/toy.rb"))
    end
  end

  # `brew audit --strict` refuses a `version` that Homebrew reads from the
  # URL as well. It reads it there when the archive name holds it, or when
  # the version is plain numbers and the tag is that version: a
  # pre-release whose archive name does not hold it is the one case where
  # Homebrew reads something else ("64" from amd64), observed with
  # Homebrew 7.0.14.
  describe "the version line" do
    {
      {"v1.2.3-rc.1", "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"} => false,
      {"v1.2.3", "{{ .ProjectName }}_{{ .Os }}_{{ .Arch }}"}                     => false,
      {"1.2.3", "{{ .ProjectName }}_{{ .Os }}_{{ .Arch }}"}                      => false,
      {"v1.2.3-rc.1", "{{ .ProjectName }}_{{ .Os }}_{{ .Arch }}"}                => true,
    }.each do |(tag, template), written|
      it "is #{written ? "" : "not "}written for the tag #{tag} and the archive #{template}" do
        Fixture.project(config: CONFIG + "\narchives:\n  - id: default\n    name_template: \"#{template}\"\n") do |project|
          ctx = spec_context(project)
          ctx.version_info = Crystalreleaser::VersionInfo.release(tag)
          Dir.mkdir_p(ctx.dist_path)
          vars = {"ProjectName" => "toy", "Version" => ctx.version_info.version}
          {"darwin" => "arm64", "linux" => "amd64"}.each do |system, arch|
            name = Crystalreleaser::Template.render(template, "t", vars.merge({"Os" => system, "Arch" => arch})) + ".tar.gz"
            artifact = Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Archive, name, "dist/#{name}",
              os: system, arch: arch, extra: {"format" => "tar.gz", "binaries" => "toy"})
            artifact.sha256 = "0" * 64
            ctx.artifacts.add(artifact)
          end
          Crystalreleaser::Pipes::Homebrew.new.run(ctx)
          formula = File.read(project.path("dist/homebrew/toy.rb"))
          formula.includes?(%(  version "#{ctx.version_info.version}"\n)).should eq(written)
        end
      end
    end
  end

  it "generates without any request, even when publishing" do
    Fixture.project(config: CONFIG) do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new { github_response(500) }
      Crystalreleaser::Pipes::Homebrew.new.run(homebrew_context(project, options, transport))
      transport.requests.should be_empty
      File.exists?(project.path("dist/homebrew/toy.rb")).should be_true
    end
  end

  describe Crystalreleaser::Pipes::HomebrewPush do
    it "belongs to the publish group and answers to --skip=homebrew" do
      pipe = Crystalreleaser::Pipes::HomebrewPush.new
      {pipe.name, pipe.group}.should eq({"homebrew", "publish"})
    end

    it "is skipped in a snapshot, and when the release itself is skipped" do
      Fixture.project(config: CONFIG) do |project|
        options = Crystalreleaser::Options.new
        options.publish = true
        ctx = homebrew_context(project, options)
        pipe = Crystalreleaser::Pipes::HomebrewPush.new
        pipe.skip?(ctx).should be_nil

        options.skip = ["release"]
        pipe.skip?(ctx).should eq("the release is skipped: the formula would point at files that are not there")

        options.skip = [] of String
        ctx.version_info = Crystalreleaser::VersionInfo.snapshot("v1.2.2", "abc1234")
        pipe.skip?(ctx).should eq("snapshot")
      end
    end

    it "does not push with --skip=release, even when run" do
      Fixture.project(config: CONFIG) do |project|
        options = Crystalreleaser::Options.new
        options.publish = true
        options.skip = ["release"]
        transport = FakeTransport.new { github_response(500) }
        generate_and_push(homebrew_context(project, options, transport))
        transport.requests.should be_empty
      end
    end
  end

  describe ".ruby_string" do
    it "escapes every interpolation Ruby knows in a double-quoted string" do
      Crystalreleaser::Pipes::Homebrew.ruby_string(%q(a "b" \ #{c} #$d #@e #f))
        .should eq(%q("a \"b\" \\ \#{c} \#$d \#@e #f"))
    end
  end

  it "refuses to write a formula with nothing to download" do
    Fixture.project(config: CONFIG) do |project|
      ctx = spec_context(project)
      Dir.mkdir_p(ctx.dist_path)
      add_archive(ctx, "linux", "amd64", "0" * 64, "zip")
      expect_raises(Crystalreleaser::PackageError,
        "brews: no tar.gz archive for darwin or linux to point the toy formula at") do
        Crystalreleaser::Pipes::Homebrew.new.run(ctx)
      end
      File.exists?(project.path("dist/homebrew/toy.rb")).should be_false
    end
  end

  it "writes the formula but does not push it while the release is a draft" do
    Fixture.project(config: CONFIG.sub("release:\n", "release:\n  draft: true\n")) do |project|
      options = Crystalreleaser::Options.new
      options.publish = true
      transport = FakeTransport.new { github_response(500) }
      log = IO::Memory.new
      generate_and_push(homebrew_context(project, options, transport, log))

      transport.requests.should be_empty
      File.exists?(project.path("dist/homebrew/toy.rb")).should be_true
      log.to_s.should contain("⚠ release.draft is set: Formula/toy.rb is not pushed, its URLs only work once the release is published\n")
    end
  end

  describe "skip_upload" do
    # homebrew_context releases v1.2.3-rc.1, a pre-release.
    {"true" => "skip_upload is set: Formula/toy.rb is not pushed",
     "auto" => "skip_upload is auto and v1.2.3-rc.1 is a pre-release: Formula/toy.rb is not pushed"}.each do |value, message|
      it "writes the formula without pushing it with skip_upload: #{value}" do
        Fixture.project(config: CONFIG + "\n    skip_upload: #{value}\n") do |project|
          options = Crystalreleaser::Options.new
          options.publish = true
          transport = FakeTransport.new { github_response(500) }
          log = IO::Memory.new
          generate_and_push(homebrew_context(project, options, transport, log))

          transport.requests.should be_empty
          File.exists?(project.path("dist/homebrew/toy.rb")).should be_true
          log.to_s.should contain("• #{message}\n")
        end
      end
    end

    it "pushes a stable version with skip_upload: auto" do
      Fixture.project(config: CONFIG + "\n    skip_upload: auto\n") do |project|
        options = Crystalreleaser::Options.new
        options.publish = true
        transport = FakeTransport.new { |request| request.method == "GET" ? github_response(404) : github_response(200) }
        ctx = homebrew_context(project, options, transport)
        ctx.version_info = Crystalreleaser::VersionInfo.release("v1.2.3")
        generate_and_push(ctx)
        transport.calls.last.should eq("PUT https://api.github.com/repos/jbox-web/homebrew-tap/contents/Formula/toy.rb")
      end
    end
  end

  it "defaults install and test to the binary" do
    Fixture.project(config: "brews:\n  - name: toy\n") do |project|
      ctx = homebrew_context(project)
      Crystalreleaser::Pipes::Homebrew.new.run(ctx)
      formula = File.read(project.path("dist/homebrew/toy.rb"))
      formula.should contain(%(  def install\n    bin.install "toy"\n  end\n))
      formula.should contain(%(  test do\n    system bin/"toy", "--version"\n  end\n))
    end
  end
end
