require "../spec_helper"

private def git_error(& : ->) : String
  expect_raises(Crystalreleaser::GitError) { yield }.message.to_s
end

describe Crystalreleaser::Git do
  it "fails outside a repository" do
    Fixture.project do |project|
      git_error { Crystalreleaser::Git.new(project.dir).commit }
        .should eq("#{project.dir} is not a git repository")
    end
  end

  it "says the directory is missing, not that git is" do
    git_error { Crystalreleaser::Git.new("/nonexistent/crystalreleaser-spec").commit }
      .should eq("/nonexistent/crystalreleaser-spec: no such directory")
  end

  describe "#github_remote" do
    it "reads the SSH, HTTPS and ssh:// forms" do
      Fixture.project do |project|
        project.init_git
        git = Crystalreleaser::Git.new(project.dir)
        project.git("remote", "add", "origin", "git@github.com:jbox-web/toy.git")
        git.github_remote.should eq({"jbox-web", "toy"})
        project.git("remote", "set-url", "origin", "https://github.com/jbox-web/other/")
        git.github_remote.should eq({"jbox-web", "other"})
        project.git("remote", "set-url", "origin", "ssh://git@github.com/jbox-web/third.git")
        git.github_remote.should eq({"jbox-web", "third"})
      end
    end

    it "reads an ssh:// URL with a port" do
      Fixture.project do |project|
        project.init_git
        project.git("remote", "add", "origin", "ssh://git@github.com:22/jbox-web/toy.git")
        Crystalreleaser::Git.new(project.dir).github_remote.should eq({"jbox-web", "toy"})
      end
    end

    it "is nil for another host that has github.com in its path" do
      Fixture.project do |project|
        project.init_git
        project.git("remote", "add", "origin", "https://mirror.example/github.com/jbox-web/toy.git")
        git = Crystalreleaser::Git.new(project.dir)
        git.github_remote.should be_nil
        project.git("remote", "set-url", "origin", "git@mirror.example:github.com/jbox-web/toy.git")
        git.github_remote.should be_nil
      end
    end

    it "is nil for a host that merely ends in github.com" do
      Fixture.project do |project|
        project.init_git
        project.git("remote", "add", "origin", "https://notgithub.com/jbox-web/toy.git")
        Crystalreleaser::Git.new(project.dir).github_remote.should be_nil
      end
    end
  end

  describe "#clean?" do
    it "counts an untracked file even when the user's git config hides them" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.git("config", "status.showUntrackedFiles", "no")
        project.write("NEW", "x")
        Crystalreleaser::Git.new(project.dir).clean?.should be_false
      end
    end

    it "is true after a commit and false with a pending change" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        git = Crystalreleaser::Git.new(project.dir)

        git.clean?.should be_true
        project.write("src/toy.cr", "puts 1\n")
        git.clean?.should be_false
      end
    end

    it "counts an untracked file as a change" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.write("NEW", "x")
        Crystalreleaser::Git.new(project.dir).clean?.should be_false
      end
    end
  end

  describe "#current_tag" do
    it "returns the semver tag of HEAD" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.tag("v1.2.0")
        Crystalreleaser::Git.new(project.dir).current_tag.should eq("v1.2.0")
      end
    end

    it "ignores a non-semver tag next to the semver one" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.tag("latest")
        project.tag("1.0.0")
        Crystalreleaser::Git.new(project.dir).current_tag.should eq("1.0.0")
      end
    end

    it "fails when HEAD carries no tag" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        git_error { Crystalreleaser::Git.new(project.dir).current_tag }
          .should eq("HEAD is not tagged: tag it with a semver version (e.g. v1.0.0) or use --snapshot")
      end
    end

    it "fails when HEAD carries only non-semver tags" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.tag("latest")
        git_error { Crystalreleaser::Git.new(project.dir).current_tag }
          .should eq("HEAD carries no semver tag (found: latest)")
      end
    end

    it "fails when HEAD carries several semver tags" do
      Fixture.project do |project|
        project.init_git
        project.commit("initial")
        project.tag("v1.0.0")
        project.tag("v1.0.1")
        git_error { Crystalreleaser::Git.new(project.dir).current_tag }
          .should eq("HEAD carries several semver tags: v1.0.0, v1.0.1")
      end
    end
  end

  describe "#previous_tag" do
    it "returns the closest tag before the given one" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.tag("v0.1.0")
        project.commit("two")
        project.commit("three")
        project.tag("v0.2.0")
        Crystalreleaser::Git.new(project.dir).previous_tag("v0.2.0").should eq("v0.1.0")
      end
    end

    it "skips the tags that are not versions" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.tag("v0.1.0")
        project.commit("two")
        project.tag("latest")
        project.tag("nightly")
        project.commit("three")
        project.tag("v0.2.0")
        Crystalreleaser::Git.new(project.dir).previous_tag("v0.2.0").should eq("v0.1.0")
      end
    end

    it "fails on a shallow clone instead of taking the tag for the first one" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.tag("v0.1.0")
        project.commit("two")
        project.tag("v0.2.0")
        clone = project.path("clone")
        project.git("clone", "-q", "--depth", "1", "--branch", "v0.2.0", "file://#{project.dir}", clone)
        git_error { Crystalreleaser::Git.new(clone).previous_tag("v0.2.0") }
          .should eq("this is a shallow clone: the history before v0.2.0 is missing, so the previous tag and " \
                     "the changelog cannot be computed; fetch the full history (actions/checkout: fetch-depth: 0)")
      end
    end

    it "is nil for the first tag" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.commit("two")
        project.tag("v0.1.0")
        Crystalreleaser::Git.new(project.dir).previous_tag("v0.1.0").should be_nil
      end
    end
  end

  describe "#last_tag" do
    it "is the closest version tag, HEAD included, skipping the others" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.tag("v0.1.0")
        project.commit("two")
        project.tag("latest")
        git = Crystalreleaser::Git.new(project.dir)
        git.last_tag.should eq("v0.1.0")
        project.tag("v0.2.0")
        git.last_tag.should eq("v0.2.0")
      end
    end

    it "is nil without any version tag" do
      Fixture.project do |project|
        project.init_git
        project.commit("one")
        project.tag("latest")
        Crystalreleaser::Git.new(project.dir).last_tag.should be_nil
      end
    end
  end

  # git takes a bare HEAD for a path as much as for a revision when a file
  # of that name is tracked.
  describe "in a repository that tracks a file named HEAD" do
    it "still reads the first commit and the commit time" do
      Fixture.project do |project|
        project.init_git
        project.write("HEAD", "a file\n")
        first = project.commit("one")
        project.commit("two")
        git = Crystalreleaser::Git.new(project.dir)

        git.first_commit.should eq(first)
        git.commit_time.should eq(Time.unix(project.commit_time))
      end
    end
  end

  describe "commit information" do
    it "reads the commit, its short form, the branch, the first commit and the commit time" do
      Fixture.project do |project|
        project.init_git
        first = project.commit("one")
        last = project.commit("two")
        git = Crystalreleaser::Git.new(project.dir)

        git.commit.should eq(last)
        git.short_commit.should eq(last[0, 7])
        git.branch.should eq("master")
        git.first_commit.should eq(first)
        git.commit_time.should eq(Time.unix(project.commit_time))
      end
    end
  end
end
