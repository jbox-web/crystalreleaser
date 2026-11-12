require "../spec_helper"

describe Crystalreleaser::Subprocess do
  describe ".run" do
    it "merges stdout and stderr in the order they were written" do
      status, output = Crystalreleaser::Subprocess.run("sh", ["-c", "echo one; echo two >&2; echo three; exit 3"])
      status.exit_code.should eq(3)
      output.should eq("one\ntwo\nthree\n")
    end

    it "closes the standard input of the command" do
      status, output = Crystalreleaser::Subprocess.run("sh", ["-c", "cat; echo done"])
      status.success?.should be_true
      output.should end_with("done\n")
    end

    it "runs in the given directory with the given environment only" do
      Fixture.project do |project|
        status, output = Crystalreleaser::Subprocess.run("/bin/sh", ["-c", "echo \"$GREETING:$HOME:\"; ls shard.yml"],
          chdir: project.dir, env: {"GREETING" => "hello", "PATH" => "/usr/bin:/bin"}, clear_env: true)
        status.success?.should be_true
        output.should eq("hello::\nshard.yml\n")
      end
    end

    it "raises when the command does not exist" do
      expect_raises(File::NotFoundError) do
        Crystalreleaser::Subprocess.run("crystalreleaser-no-such-command", [] of String)
      end
    end

    # The command only prints its second line once the flag file exists, and
    # gives up after 5 seconds: the block must see the first line while the
    # command is still running.
    it "yields each line as soon as the command writes it" do
      Fixture.project do |project|
        script = "echo first; n=0; while [ ! -e flag ] && [ $n -lt 100 ]; do sleep 0.05; n=$((n+1)); done; " \
                 "[ -e flag ] && echo second || echo gave-up"
        lines = [] of String
        status, output = Crystalreleaser::Subprocess.run("sh", ["-c", script], chdir: project.dir) do |line|
          lines << line
          File.touch(project.path("flag")) if line == "first"
        end
        status.success?.should be_true
        lines.should eq(["first", "second"])
        output.should eq("first\nsecond\n")
      end
    end
  end

  describe ".describe" do
    it "names the exit code" do
      status, _ = Crystalreleaser::Subprocess.run("sh", ["-c", "exit 7"])
      Crystalreleaser::Subprocess.describe(status).should eq("exit 7")
    end

    it "names the signal that killed the command" do
      status, _ = Crystalreleaser::Subprocess.run("sh", ["-c", "kill -9 $$"])
      Crystalreleaser::Subprocess.describe(status).should eq("killed by signal KILL")
    end
  end
end
