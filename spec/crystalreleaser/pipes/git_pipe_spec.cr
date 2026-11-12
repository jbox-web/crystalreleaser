require "../../spec_helper"

private def run_git_pipe(project, snapshot = false) : Crystalreleaser::Context
  options = Crystalreleaser::Options.new
  options.snapshot = snapshot
  ctx = spec_context(project, options: options)
  Crystalreleaser::Pipes::Git.new.run(ctx)
  ctx
end

describe Crystalreleaser::Pipes::Git do
  it "reads the tag, the previous tag and the commit of a release" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      project.tag("v1.0.0")
      last = project.commit("two")
      project.tag("v1.1.0")
      ctx = run_git_pipe(project)

      ctx.version_info.tag.should eq("v1.1.0")
      ctx.version_info.version.should eq("1.1.0")
      ctx.previous_tag.should eq("v1.0.0")
      ctx.commit.should eq(last)
      ctx.short_commit.should eq(last[0, 7])
      ctx.commit_time.should eq(Time.unix(project.commit_time))
    end
  end

  it "refuses a dirty tree and lists the changes" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      project.tag("v1.0.0")
      project.write("src/toy.cr", "changed\n")
      expect_raises(Crystalreleaser::GitError,
        "git is in a dirty state, commit or stash these changes, or use --snapshot:\n   M src/toy.cr") do
        run_git_pipe(project)
      end
    end
  end

  it "accepts a dirty untagged tree in snapshot mode" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      project.tag("v1.4.2")
      project.commit("two")
      project.write("src/toy.cr", "changed\n")
      ctx = run_git_pipe(project, snapshot: true)

      ctx.version_info.version.should eq("1.4.3-SNAPSHOT-#{ctx.short_commit}")
      ctx.previous_tag.should eq("v1.4.2")
    end
  end

  # actions/checkout fetches one commit and no tag by default: the version
  # then starts from nothing, and gets baked into the binaries.
  it "warns about a snapshot on a shallow clone where no tag is in reach" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      project.tag("v1.4.2")
      project.commit("two")
      clone = Fixture::Project.new(project.path("clone"))
      project.git("clone", "-q", "--depth", "1", "--no-tags", "file://#{project.dir}", clone.dir)
      log = IO::Memory.new
      ctx = spec_context(clone, options: Crystalreleaser::Options.new.tap(&.snapshot=(true)), log: log)
      Crystalreleaser::Pipes::Git.new.run(ctx)

      ctx.version_info.version.should eq("0.0.1-SNAPSHOT-#{ctx.short_commit}")
      log.to_s.should contain("⚠ this is a shallow clone and no version tag is in reach: the snapshot version starts " \
                              "from 0.0.0; fetch the full history (actions/checkout: fetch-depth: 0)\n")
    end
  end

  it "does not warn about a snapshot in a full repository without any tag" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      log = IO::Memory.new
      ctx = spec_context(project, options: Crystalreleaser::Options.new.tap(&.snapshot=(true)), log: log)
      Crystalreleaser::Pipes::Git.new.run(ctx)
      log.to_s.should_not contain("shallow")
    end
  end

  it "warns when shard.yml disagrees with the tag" do
    Fixture.project do |project|
      project.init_git
      project.commit("one")
      project.tag("v2.0.0")
      log = IO::Memory.new
      ctx = spec_context(project, log: log)
      Crystalreleaser::Pipes::Git.new.run(ctx)

      log.to_s.should contain("⚠ shard.yml version 0.1.0 does not match the tag version 2.0.0\n")
    end
  end
end
