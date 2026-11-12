require "../spec_helper"

VERSION_LINE = %r{\Acrystalreleaser \S+ \((unknown|[0-9a-f]{8}(-dirty)?), [a-z]+/[a-z0-9]+\)\n\z}

describe Crystalreleaser::CLI do
  describe "--version" do
    it "prints the self-naming version line and succeeds" do
      run = run_cli("--version")

      run.code.should eq(0)
      run.stdout.should match(VERSION_LINE)
      run.stderr.should be_empty
    end
  end

  describe "without a command" do
    it "prints the usage on stdout and succeeds" do
      run = run_cli

      run.code.should eq(0)
      run.stdout.should start_with("Usage: crystalreleaser <command> [options]\n")
      %w[init check build release changelog licenses].each do |command|
        run.stdout.should contain("    #{command}")
      end
    end
  end

  describe "--help" do
    it "prints the usage on stdout and succeeds" do
      run = run_cli("--help")

      run.code.should eq(0)
      run.stdout.should start_with("Usage: crystalreleaser <command> [options]\n")
    end
  end

  describe "--help after a command" do
    it "shows the options of build" do
      run = run_cli("build", "--help")
      run.code.should eq(0)
      run.stdout.should start_with("Usage: crystalreleaser build [options]\n")
      %w[--snapshot --clean --id --split --os --arch --parallelism].each { |flag| run.stdout.should contain(flag) }
      run.stdout.should_not contain("--merge")
    end

    it "shows the options of release" do
      run = run_cli("release", "--help")
      run.stdout.should start_with("Usage: crystalreleaser release [options]\n")
      %w[--snapshot --clean --merge --allow-missing --skip --release-notes --parallelism].each { |flag| run.stdout.should contain(flag) }
    end
  end

  describe "arguments after --" do
    it "are refused rather than ignored" do
      run = run_cli("--", "check")
      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: unexpected argument: check\n")
    end
  end

  describe "input and output errors" do
    it "says it cannot write the config, without a backtrace" do
      Fixture.project do |project|
        run = run_cli_in(project.dir, "init", "-f", "missing/dir/x.yml")
        run.code.should eq(1)
        run.stderr.should start_with("crystalreleaser: cannot write missing/dir/x.yml: ")
        run.stderr.lines.size.should eq(1)
      end
    end

    it "says it cannot read the config, without a backtrace" do
      pending!("root reads every file") if LibC.getuid == 0
      Fixture.project(config: "project_name: toy\n") do |project|
        File.chmod(project.path(".crystalreleaser.yml"), 0o000)
        run = run_cli_in(project.dir, "check")
        run.code.should eq(1)
        run.stderr.lines.last.should start_with("crystalreleaser: cannot read .crystalreleaser.yml: ")
      end
    end

    it "stops quietly when its output is closed, as in `--help | head`" do
      closed = IO::Memory.new
      closed.close
      stderr = IO::Memory.new
      Crystalreleaser::CLI.new(closed, stderr, Dir.current).run(["--help"]).should eq(1)
      stderr.to_s.should be_empty
    end
  end

  describe "an unknown command" do
    it "fails with code 1 and names the command" do
      run = run_cli("frobnicate")

      run.code.should eq(1)
      run.stdout.should be_empty
      run.stderr.should eq("crystalreleaser: unknown command: frobnicate\n")
    end
  end

  describe "an unknown option" do
    it "fails with code 1 and names the option" do
      run = run_cli("--frobnicate")

      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: unknown option: --frobnicate\n")
    end
  end

  describe "an error" do
    it "is reported in one line with code 1" do
      Fixture.project do |project|
        File.delete(project.path("shard.yml"))
        run = run_cli_in(project.dir, "check")

        run.code.should eq(1)
        run.stderr.lines.last.should eq("crystalreleaser: shard.yml not found in #{project.dir}")
        run.stderr.should_not contain(".cr:")
      end
    end

    it "adds the backtrace under --verbose" do
      Fixture.project do |project|
        File.delete(project.path("shard.yml"))
        run = run_cli_in(project.dir, "--verbose", "check")

        run.code.should eq(1)
        run.stderr.should contain("crystalreleaser: shard.yml not found in #{project.dir}\n")
        run.stderr.should contain(".cr:")
      end
    end
  end

  describe "options that are wrong before anything runs" do
    it "refuses --allow-missing without --merge" do
      Fixture.project do |project|
        run = run_cli_in(project.dir, "release", "--snapshot", "--allow-missing")
        run.code.should eq(1)
        run.stderr.should end_with("crystalreleaser: --allow-missing needs --merge\n")
      end
    end

    {"0", "-2", "many"}.each do |value|
      it "refuses --parallelism #{value}" do
        run = run_cli("build", "--parallelism", value)
        run.code.should eq(1)
        run.stderr.should eq("crystalreleaser: --parallelism expects a positive number, got '#{value}'\n")
      end
    end

    it "names the option whose value is missing" do
      run = run_cli("build", "--id")
      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: missing value for option: --id\n")
    end
  end

  describe "--verbose and --quiet together" do
    it "is a usage error" do
      run = run_cli("--verbose", "--quiet", "check")

      run.code.should eq(1)
      run.stderr.should eq("crystalreleaser: --verbose and --quiet are mutually exclusive\n")
    end
  end

  describe "licenses" do
    it "prints every embedded notice, each under its own header" do
      run = run_cli("licenses")

      run.code.should eq(0)
      run.stdout.should contain("==> crystalreleaser.txt <==\n")
      run.stdout.should contain("==> clib-Apache-2.0.txt <==\n")
      # The project's own MIT text, carried verbatim from LICENSE.
      run.stdout.should contain("Copyright (c) 2022-2026 Nicolas Rodriguez")
    end
  end
end
