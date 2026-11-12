require "../spec_helper"

describe "crystalreleaser init" do
  it "writes a commented config derived from shard.yml that check accepts" do
    Fixture.project do |project|
      project.init_git
      project.git("remote", "add", "origin", "git@github.com:jbox-web/toy.git")
      run = run_cli_in(project.dir, "init")
      run.code.should eq(0), run.stderr
      run.stderr.should eq("• wrote .crystalreleaser.yml\n")

      config = File.read(project.path(".crystalreleaser.yml"))
      config.should start_with("# crystalreleaser configuration for toy.\n")
      config.should contain("  - id: toy\n    target: toy\n")
      config.should contain("      - TOY_VERSION={{ .Version }}\n")
      config.should contain("    owner: jbox-web\n    name: toy\n")

      check = run_cli_in(project.dir, "check")
      check.code.should eq(0), check.stderr
    end
  end

  it "declares the version-injection variable of every target" do
    shard = "name: duo\nversion: 1.0.0\ntargets:\n  duo-cli:\n    main: src/cli.cr\n  duo-server:\n    main: src/server.cr\n"
    Fixture.project(shard: shard) do |project|
      run_cli_in(project.dir, "init").code.should eq(0)
      config = File.read(project.path(".crystalreleaser.yml"))
      config.should contain("      - DUO_CLI_VERSION={{ .Version }}\n")
      config.should contain("      - DUO_SERVER_VERSION={{ .Version }}\n")
      run_cli_in(project.dir, "check").code.should eq(0)
    end
  end

  it "quotes names YAML would misread, and keeps variable names valid" do
    shard = "name: \"on\"\nversion: 1.0.0\ntargets:\n  \"123\":\n    main: src/toy.cr\n"
    Fixture.project(shard: shard) do |project|
      run_cli_in(project.dir, "init").code.should eq(0)
      config = File.read(project.path(".crystalreleaser.yml"))
      config.should contain(%(project_name: "on"\n))
      config.should contain(%(  - id: "123"\n    target: "123"\n))
      config.should contain("      - _123_VERSION={{ .Version }}\n")
      check = run_cli_in(project.dir, "check")
      check.code.should eq(0), check.stderr
    end
  end

  # A placeholder owner would pass `check` and only fail a release once
  # everything is built.
  it "leaves the release repository commented out when there is no GitHub remote" do
    Fixture.project do |project|
      run_cli_in(project.dir, "init").code.should eq(0)
      config = File.read(project.path(".crystalreleaser.yml"))
      config.should contain("release:\n  # github:\n  #   owner: OWNER\n  #   name: toy\n  prerelease: auto\n")
      Crystalreleaser::Config.load(project.dir, nil, Crystalreleaser::Host.current).release.github.should be_nil
      run_cli_in(project.dir, "check").code.should eq(0)
    end
  end

  it "writes any project name as YAML reads it back" do
    [%q(a"b), %q(a\b), "a\#{b}", "tab\there", "é: x", "true", "12"].each do |name|
      text = "project_name: #{Crystalreleaser::Init.scalar(name)}\n"
      YAML.parse(text)["project_name"].as_s?.should eq(name)
    end
  end

  it "refuses a shard without target: there would be nothing to build" do
    Fixture.project(shard: "name: lib\nversion: 1.0.0\n") do |project|
      run = run_cli_in(project.dir, "init")
      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: shard.yml declares no target: there is nothing to build or release\n")
      File.exists?(project.path(".crystalreleaser.yml")).should be_false
    end
  end

  it "refuses to overwrite an existing config" do
    Fixture.project(config: "project_name: toy\n") do |project|
      run = run_cli_in(project.dir, "init")
      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: .crystalreleaser.yml already exists\n")
    end
  end

  it "writes to the file given with -f" do
    Fixture.project do |project|
      run_cli_in(project.dir, "init", "-f", "release.yml").code.should eq(0)
      File.exists?(project.path("release.yml")).should be_true
      run_cli_in(project.dir, "check", "-f", "release.yml").code.should eq(0)
    end
  end
end
