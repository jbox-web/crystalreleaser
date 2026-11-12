require "../../spec_helper"

private GROUPED = <<-YAML
  changelog:
    filters:
      exclude: ["^docs:", "^chore", "Merge pull request"]
    groups:
      - title: Features
        regexp: '^feat(\\(.+\\))?!?:'
      - title: Bug fixes
        regexp: '^fix(\\(.+\\))?!?:'
      - title: Others
  YAML

# Newest first, as `git log` lists them.
private COMMITS = [
  {"7777777aaaa", "Merge pull request #3 from x/y"},
  {"6666666aaaa", "feat(cli): add --quiet"},
  {"5555555aaaa", "refactor: split the pipeline"},
  {"4444444aaaa", "fix: archive mode"},
  {"3333333aaaa", "docs: readme"},
  {"2222222aaaa", "feat: archives"},
  {"1111111aaaa", "chore(deps): bump"},
]

private def changelog_config(yaml : String) : Crystalreleaser::Config::Changelog
  Crystalreleaser::Config.parse(yaml, "spec.yml").changelog
end

describe Crystalreleaser::Pipes::Changelog do
  describe ".render" do
    it "groups, filters and sorts oldest first" do
      Crystalreleaser::Pipes::Changelog.render(COMMITS, changelog_config(GROUPED)).should eq(<<-MD)
        ## Changelog

        ### Features

        * 2222222 feat: archives
        * 6666666 feat(cli): add --quiet

        ### Bug fixes

        * 4444444 fix: archive mode

        ### Others

        * 5555555 refactor: split the pipeline

        MD
    end

    it "sorts newest first with sort: desc and lists everything without groups" do
      config = changelog_config("changelog:\n  sort: desc\n  filters:\n    exclude: ['^(docs|chore)', 'Merge']\n")
      Crystalreleaser::Pipes::Changelog.render(COMMITS, config).should eq(<<-MD)
        ## Changelog

        * 6666666 feat(cli): add --quiet
        * 5555555 refactor: split the pipeline
        * 4444444 fix: archive mode
        * 2222222 feat: archives

        MD
    end

    it "omits empty groups and drops commits no group catches" do
      config = changelog_config("changelog:\n  groups:\n    - title: Fixes\n      regexp: '^fix'\n    - title: Docs\n      regexp: '^nothing'\n")
      Crystalreleaser::Pipes::Changelog.render(COMMITS, config).should eq(<<-MD)
        ## Changelog

        ### Fixes

        * 4444444 fix: archive mode

        MD
    end
  end

  describe "#run" do
    it "takes the commits since the previous tag and writes dist/CHANGELOG.md" do
      Fixture.project(config: GROUPED) do |project|
        project.init_git
        project.commit("feat: before the tag")
        project.tag("v1.0.0")
        fix = project.commit("fix: after the tag")
        feat = project.commit("feat: also after")
        ctx = spec_context(project)
        ctx.previous_tag = "v1.0.0"
        Dir.mkdir_p(ctx.dist_path)
        Crystalreleaser::Pipes::Changelog.new.run(ctx)

        expected = "## Changelog\n\n### Features\n\n* #{feat[0, 7]} feat: also after\n\n" \
                   "### Bug fixes\n\n* #{fix[0, 7]} fix: after the tag\n"
        File.read(project.path("dist/CHANGELOG.md")).should eq(expected)
        ctx.changelog.should eq(expected)
      end
    end

    it "lists the commits of a repository that tracks a file named HEAD" do
      Fixture.project do |project|
        project.init_git
        project.write("HEAD", "a file\n")
        one = project.commit("feat: one")
        ctx = spec_context(project)
        ctx.previous_tag = nil
        Crystalreleaser::Pipes::Changelog.commits(ctx).should eq([{one, "feat: one"}])
      end
    end

    it "starts at the first commit when there is no previous tag" do
      Fixture.project do |project|
        project.init_git
        first = project.commit("first")
        second = project.commit("second")
        ctx = spec_context(project)
        ctx.previous_tag = nil
        Dir.mkdir_p(ctx.dist_path)
        Crystalreleaser::Pipes::Changelog.new.run(ctx)

        ctx.changelog.should eq("## Changelog\n\n* #{first[0, 7]} first\n* #{second[0, 7]} second\n")
      end
    end

    it "uses the file given with --release-notes instead" do
      Fixture.project do |project|
        project.init_git
        project.commit("first")
        project.write("NOTES.md", "Hand-written notes\n")
        options = Crystalreleaser::Options.new
        options.release_notes = "NOTES.md"
        ctx = spec_context(project, options: options)
        Dir.mkdir_p(ctx.dist_path)
        Crystalreleaser::Pipes::Changelog.new.run(ctx)

        File.read(project.path("dist/CHANGELOG.md")).should eq("Hand-written notes\n")
      end
    end

    it "fails when the release notes file is missing" do
      Fixture.project do |project|
        options = Crystalreleaser::Options.new
        options.release_notes = "NOPE.md"
        expect_raises(Crystalreleaser::UsageError, "release notes file not found: NOPE.md") do
          Crystalreleaser::Pipes::Changelog.new.run(spec_context(project, options: options))
        end
      end
    end
  end
end
