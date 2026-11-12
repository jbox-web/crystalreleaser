require "../spec_helper"

describe "crystalreleaser check" do
  it "validates the defaults when there is no config file" do
    Fixture.project do |project|
      run = run_cli_in(project.dir, "check")

      run.code.should eq(0)
      run.stdout.should be_empty
      run.stderr.should eq(
        "• no configuration file, using defaults from shard.yml\n" \
        "• configuration is valid\n"
      )
    end
  end

  it "names the file it loaded and prints the warnings" do
    config = <<-YAML
      builds:
        - id: toy
          target: toy
          cross:
            sysroot: /s
          platforms:
            - os: windows
              arch: amd64
              strategy: cross
      YAML
    Fixture.project(config: config) do |project|
      run = run_cli_in(project.dir, "check")

      run.code.should eq(0)
      run.stderr.should eq(
        "• loading configuration file=.crystalreleaser.yml\n" \
        "  ⚠ builds[0].platforms[0]: windows/amd64 is accepted but cannot be built yet; it will be skipped\n" \
        "• configuration is valid\n"
      )
    end
  end

  it "uses the file given with -f" do
    Fixture.project do |project|
      project.write("ci.yml", "project_name: toy\n")
      run = run_cli_in(project.dir, "check", "-f", "ci.yml")

      run.code.should eq(0)
      run.stderr.should start_with("• loading configuration file=ci.yml\n")
    end
  end

  it "fails with every error and code 1" do
    Fixture.project(config: "version: 2\nenv: [NOPE]\n") do |project|
      run = run_cli_in(project.dir, "check")

      run.code.should eq(1)
      run.stderr.should eq(
        "• loading configuration file=.crystalreleaser.yml\n" \
        "crystalreleaser: invalid configuration:\n" \
        "  - version: unsupported config version 2 (expected 1)\n" \
        "  - env[0]: expected KEY=VALUE, got 'NOPE'\n"
      )
    end
  end

  it "only prints warnings and errors under --quiet" do
    Fixture.project do |project|
      run_cli_in(project.dir, "--quiet", "check").stderr.should be_empty
    end
  end
end
