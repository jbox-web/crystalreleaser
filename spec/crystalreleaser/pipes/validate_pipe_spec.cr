require "../../spec_helper"

private def publishing_options(snapshot = false, skip = [] of String) : Crystalreleaser::Options
  options = Crystalreleaser::Options.new
  options.publish = true
  options.snapshot = snapshot
  options.skip = skip
  options
end

describe Crystalreleaser::Pipes::Validate do
  it "logs the warnings of a valid config" do
    Fixture.project(config: "builds:\n  - id: toy\n    target: toy\n    platforms:\n      - os: darwin\n        arch: arm64\n") do |project|
      log = IO::Memory.new
      Crystalreleaser::Pipes::Validate.new.run(spec_context(project, log: log))
      log.to_s.should eq("⚠ builds[0].platforms[0]: native build of darwin/arm64 on a linux/amd64 host will be skipped\n")
    end
  end

  it "fails before any build when publishing without a token" do
    Fixture.project do |project|
      expect_raises(Crystalreleaser::ConfigError,
        "publishing needs GITHUB_TOKEN or GH_TOKEN: set one, or use --skip=publish or --snapshot") do
        Crystalreleaser::Pipes::Validate.new.run(spec_context(project, options: publishing_options))
      end
    end
  end

  it "accepts GH_TOKEN as well as GITHUB_TOKEN" do
    Fixture.project(config: "release:\n  github:\n    owner: o\n    name: r\n") do |project|
      ctx = spec_context(project, options: publishing_options, env: {"GH_TOKEN" => "t"})
      Crystalreleaser::Pipes::Validate.new.run(ctx)
    end
  end

  it "fails before any build when the release repository is unknown" do
    Fixture.project do |project|
      project.init_git
      ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t"})
      expect_raises(Crystalreleaser::ConfigError, "release.github is not set and the origin remote is not a GitHub repository") do
        Crystalreleaser::Pipes::Validate.new.run(ctx)
      end
    end
  end

  describe "the tap and registry tokens, checked before the release is published" do
    release = "release:\n  github:\n    owner: o\n    name: r\n"
    tap = "    repository:\n      owner: o\n      name: tap\n      token: \"{{ .Env.TAP_TOKEN }}\"\n"

    it "fails when the variable of a brew token is not set" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n#{tap}") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t"})
        expect_raises(Crystalreleaser::TemplateError, "brews[0].repository.token: environment variable TAP_TOKEN is not set") do
          Crystalreleaser::Pipes::Validate.new.run(ctx)
        end
      end
    end

    it "fails when a brew token renders empty, rather than falling back on GITHUB_TOKEN" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n#{tap}") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t", "TAP_TOKEN" => ""})
        expect_raises(Crystalreleaser::ConfigError, "brews[0].repository.token: the token is empty") do
          Crystalreleaser::Pipes::Validate.new.run(ctx)
        end
      end
    end

    it "fails when a brew has no repository to push to" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t"})
        expect_raises(Crystalreleaser::ConfigError, "brews[0].repository is required to publish the formula") do
          Crystalreleaser::Pipes::Validate.new.run(ctx)
        end
      end
    end

    it "fails when an aqua token renders empty" do
      Fixture.project(config: "#{release}aqua:\n  - path: registry.yaml\n#{tap}") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t", "TAP_TOKEN" => " "})
        expect_raises(Crystalreleaser::ConfigError, "aqua[0].repository.token: the token is empty") do
          Crystalreleaser::Pipes::Validate.new.run(ctx)
        end
      end
    end

    # The same project without `skip_upload: true` is refused: the run below
    # passes because of the exemption, not because nothing was checked.
    it "asks nothing of a brew that is never pushed" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n    skip_upload: true\n") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t"})
        Crystalreleaser::Pipes::Validate.new.run(ctx).should be_nil
      end
      Fixture.project(config: "#{release}brews:\n  - name: toy\n") do |project|
        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t"})
        expect_raises(Crystalreleaser::ConfigError, "brews[0].repository is required to publish the formula") do
          Crystalreleaser::Pipes::Validate.new.run(ctx)
        end
      end
    end

    it "asks nothing of the tap when the release itself is skipped: nothing is pushed then" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n#{tap}") do |project|
        skipped = publishing_options(skip: ["release"])
        Crystalreleaser::Pipes::Validate.new.run(spec_context(project, options: skipped, env: {"GITHUB_TOKEN" => "t"}))
      end
    end

    # Each client the checks build is counted: none would mean the run
    # returned before reaching them.
    it "passes with every token set, and ignores a pipe that is skipped" do
      Fixture.project(config: "#{release}brews:\n  - name: toy\n#{tap}") do |project|
        tokens = [] of String
        factory = ->(token : String) { tokens << token; fake_client(FakeTransport.new { github_response(500) }).as(Crystalreleaser::Github::Client) }

        ctx = spec_context(project, options: publishing_options, env: {"GITHUB_TOKEN" => "t", "TAP_TOKEN" => "tap"})
        ctx.github_client_factory = factory
        Crystalreleaser::Pipes::Validate.new.run(ctx)
        tokens.should eq(["tap"])

        tokens.clear
        ctx = spec_context(project, options: publishing_options(skip: ["homebrew"]), env: {"GITHUB_TOKEN" => "t"})
        ctx.github_client_factory = factory
        Crystalreleaser::Pipes::Validate.new.run(ctx)
        tokens.should be_empty
      end
    end
  end

  # Still validated: the warning of the config is logged in both cases, so
  # the run did not simply return.
  it "does not need a token for a snapshot or when publishing is skipped" do
    config = "builds:\n  - id: toy\n    target: toy\n    platforms:\n      - os: darwin\n        arch: arm64\n"
    Fixture.project(config: config) do |project|
      {publishing_options(snapshot: true), publishing_options(skip: ["publish"])}.each do |options|
        log = IO::Memory.new
        Crystalreleaser::Pipes::Validate.new.run(spec_context(project, options: options, log: log))
        log.to_s.should eq("⚠ builds[0].platforms[0]: native build of darwin/arm64 on a linux/amd64 host will be skipped\n")
      end
    end
  end
end
