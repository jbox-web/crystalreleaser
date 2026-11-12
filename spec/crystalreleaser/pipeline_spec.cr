require "../spec_helper"

# Records its runs in a shared journal; skips itself when given a reason.
private class RecordingPipe < Crystalreleaser::Pipe
  getter name : String
  getter group : String?

  def initialize(@name : String, @journal : Array(String), @reason : String? = nil, @group : String? = nil)
  end

  def description : String
    "running #{@name}"
  end

  def skip?(ctx : Crystalreleaser::Context) : String?
    @reason
  end

  def run(ctx : Crystalreleaser::Context) : Nil
    @journal << @name
    ctx.logger.info("inside #{@name}")
  end
end

private def run_pipeline(project, pipes, options = Crystalreleaser::Options.new) : String
  log = IO::Memory.new
  ctx = spec_context(project, options: options, log: log)
  Crystalreleaser::Pipeline.new(pipes).run(ctx)
  log.to_s
end

describe Crystalreleaser::Pipeline do
  # Whatever can still fail (two archives for one platform, archive names
  # that follow no template) must fail before the release is public.
  it "generates the formula and the registry entry before the release, and pushes them after" do
    Crystalreleaser::Pipeline.release.pipes.map(&.class.name.lchop("Crystalreleaser::Pipes::")).should eq(%w[
      Validate Shard Git BeforeHooks Build Archive Nfpm Checksum Changelog Metadata
      Homebrew Aqua Release HomebrewPush AquaPush
    ])
    Crystalreleaser::Pipeline.release(merge: true).pipes.map(&.class.name.lchop("Crystalreleaser::Pipes::")).should eq(%w[
      Validate Shard Git Merge Archive Nfpm Checksum Changelog Metadata
      Homebrew Aqua Release HomebrewPush AquaPush
    ])
  end

  it "runs the pipes in order, one indented block per pipe" do
    Fixture.project do |project|
      journal = [] of String
      log = run_pipeline(project, [RecordingPipe.new("a", journal), RecordingPipe.new("b", journal)])

      journal.should eq(["a", "b"])
      log.should eq("• running a\n  • inside a\n• running b\n  • inside b\n")
    end
  end

  it "skips a pipe that gives a reason, and says why" do
    Fixture.project do |project|
      journal = [] of String
      log = run_pipeline(project, [RecordingPipe.new("a", journal, "nothing to do")])

      journal.should be_empty
      log.should eq("• running a skipped: nothing to do\n")
    end
  end

  it "skips the pipes named in --skip, by name or by group" do
    Fixture.project do |project|
      journal = [] of String
      options = Crystalreleaser::Options.new
      options.skip = ["a", "publish"]
      pipes = [
        RecordingPipe.new("a", journal),
        RecordingPipe.new("b", journal),
        RecordingPipe.new("release", journal, group: "publish"),
      ]
      log = run_pipeline(project, pipes, options)

      journal.should eq(["b"])
      log.should contain("• running a skipped: --skip=a\n")
      log.should contain("• running release skipped: --skip=publish\n")
    end
  end

  it "rejects an unknown name in --skip before running anything" do
    Fixture.project do |project|
      journal = [] of String
      options = Crystalreleaser::Options.new
      options.skip = ["nope"]
      expect_raises(Crystalreleaser::UsageError, "unknown pipe in --skip: nope (known: a, publish)") do
        run_pipeline(project, [RecordingPipe.new("a", journal, group: "publish")], options)
      end
      journal.should be_empty
    end
  end

  describe "the dist directory" do
    it "is created when missing" do
      Fixture.project do |project|
        run_pipeline(project, [] of Crystalreleaser::Pipe)
        Dir.exists?(project.path("dist")).should be_true
      end
    end

    it "must be empty without --clean" do
      Fixture.project do |project|
        project.write("dist/old.txt", "x")
        expect_raises(Crystalreleaser::Error, "dist/ is not empty: remove it or use --clean") do
          run_pipeline(project, [] of Crystalreleaser::Pipe)
        end
      end
    end

    it "is never removed when it is the project itself, even with --clean" do
      Fixture.project(config: "dist: .\n") do |project|
        options = Crystalreleaser::Options.new
        options.clean = true
        expect_raises(Crystalreleaser::ConfigError, %(dist: must be a directory inside the project, got ".")) do
          run_pipeline(project, [] of Crystalreleaser::Pipe, options)
        end
        File.exists?(project.path("shard.yml")).should be_true
        File.exists?(project.path("src/toy.cr")).should be_true
      end
    end

    # `dist: src` is a directory inside the project, and without --clean the
    # error itself says "remove it or use --clean".
    it "is never removed when it holds files tracked by git, even with --clean" do
      Fixture.project(config: "dist: src\n") do |project|
        project.init_git
        project.commit("feat: first")
        options = Crystalreleaser::Options.new
        options.clean = true
        expect_raises(Crystalreleaser::ConfigError, "dist: src/ holds files tracked by git (src/toy.cr): --clean would delete them") do
          run_pipeline(project, [] of Crystalreleaser::Pipe, options)
        end
        File.exists?(project.path("src/toy.cr")).should be_true
      end
    end

    # rm_rf reports nothing: what it could not remove would be archived,
    # checksummed and uploaded with the new files.
    it "fails when --clean cannot remove everything" do
      Fixture.project do |project|
        pending!("root removes anything") if LibC.getuid == 0
        project.write("dist/locked/old.txt", "x")
        File.chmod(project.path("dist/locked"), 0o555)
        options = Crystalreleaser::Options.new
        options.clean = true
        begin
          expect_raises(Crystalreleaser::Error, "dist/ could not be emptied: remove it by hand") do
            run_pipeline(project, [] of Crystalreleaser::Pipe, options)
          end
        ensure
          File.chmod(project.path("dist/locked"), 0o755)
        end
      end
    end

    it "is emptied with --clean" do
      Fixture.project do |project|
        project.write("dist/old/file.txt", "x")
        options = Crystalreleaser::Options.new
        options.clean = true
        run_pipeline(project, [] of Crystalreleaser::Pipe, options)
        Dir.children(project.path("dist")).should be_empty
      end
    end
  end
end
