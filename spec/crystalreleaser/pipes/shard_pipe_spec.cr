require "../../spec_helper"

describe Crystalreleaser::Pipes::Shard do
  describe ".satisfies?" do
    it "follows the shards constraint operators" do
      {
        {"1.20.3", ">= 1.18.0"} => true,
        {"1.17.1", ">= 1.18.0"} => false,
        {"1.20.3", "> 1.20.3"}  => false,
        {"1.20.3", "< 2.0.0"}   => true,
        {"1.20.3", "<= 1.20"}   => false,
        {"1.20.3", "= 1.20.3"}  => true,
        {"1.20.3", "1.20.3"}    => true,
        # A bare version is a minimum, as shard.yml(5) defines it.
        {"1.20.3", "1.0.0"}             => true,
        {"1.20.3", "2.0.0"}             => false,
        {"1.20.3", "!= 1.20.3"}         => false,
        {"1.20.3", "!= 1.19.0"}         => true,
        {"1.20.3", ">= 1.0.0-dev"}      => true,
        {"1.20.3", "~> 1.19"}           => true,
        {"2.0.0", "~> 1.19"}            => false,
        {"1.20.3", "~> 1.20.0"}         => true,
        {"1.21.0", "~> 1.20.0"}         => false,
        {"1.20.3", ">= 1.18.0, < 2.0"}  => true,
        {"1.20.3", ">= 1.18.0, < 1.19"} => false,
        {"1.20.3", "*"}                 => true,
      }.each do |(version, constraint), expected|
        Crystalreleaser::Pipes::Shard.satisfies?(version, constraint).should eq(expected), "#{version} #{constraint}"
      end
    end
  end

  it "does not answer for a constraint it cannot read" do
    Crystalreleaser::Pipes::Shard.satisfies?("1.20.3", "garbage").should be_nil
    Fixture.project(shard: Fixture::DEFAULT_SHARD + "\ncrystal: garbage\n") do |project|
      log = IO::Memory.new
      Crystalreleaser::Pipes::Shard.new.run(spec_context(project, log: log))
      log.to_s.should eq("⚠ cannot read shard.yml crystal: garbage\n")
    end
  end

  it "is skipped when shard.yml sets no crystal constraint" do
    Fixture.project do |project|
      Crystalreleaser::Pipes::Shard.new.skip?(spec_context(project)).should eq("no crystal constraint in shard.yml")
    end
  end

  it "warns when the installed crystal does not satisfy shard.yml" do
    Fixture.project(shard: Fixture::DEFAULT_SHARD + "\ncrystal: \">= 9.0.0\"\n") do |project|
      log = IO::Memory.new
      ctx = spec_context(project, log: log)
      Crystalreleaser::Pipes::Shard.new.run(ctx)
      log.to_s.should eq("⚠ crystal 1.20.3 does not satisfy shard.yml crystal: >= 9.0.0\n")
    end
  end

  it "confirms when the constraint is satisfied" do
    Fixture.project(shard: Fixture::DEFAULT_SHARD + "\ncrystal: \">= 1.18.0\"\n") do |project|
      log = IO::Memory.new
      Crystalreleaser::Pipes::Shard.new.run(spec_context(project, log: log))
      log.to_s.should eq("• crystal 1.20.3 satisfies >= 1.18.0\n")
    end
  end
end
