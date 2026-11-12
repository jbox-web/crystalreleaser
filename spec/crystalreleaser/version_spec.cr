require "../spec_helper"

# Every value here is captured at compile time and differs between a checkout,
# a tarball and a release build, so the specs assert the *shape* of the
# provenance, never a literal commit.
# VERSION as a program compiled with `env` added to the environment reports it.
private def compiled_version(env : Hash(String, String)) : String
  source = %(require "./src/crystalreleaser/version"\nprint Crystalreleaser::VERSION\n)
  output = IO::Memory.new
  error = IO::Memory.new
  full = ENV.to_h.reject("CRYSTALRELEASER_VERSION").merge(env)
  status = Process.run("crystal", ["eval", source], env: full, clear_env: true, output: output, error: error,
    chdir: File.expand_path("../..", __DIR__))
  raise "crystal eval failed: #{error}" unless status.success?
  output.to_s
end

describe Crystalreleaser do
  describe "VERSION" do
    # Compiled for real, with the variable as a release build sets it: the
    # constant is fixed at compile time, so the spec binary cannot show both
    # branches.
    it "is CRYSTALRELEASER_VERSION when set at compile time" do
      compiled_version({"CRYSTALRELEASER_VERSION" => "9.8.7-rc.1"}).should eq("9.8.7-rc.1")
    end

    it "is the shard version when the variable is unset or empty" do
      shard_version = YAML.parse(File.read("#{__DIR__}/../../shard.yml"))["version"].as_s
      compiled_version({} of String => String).should eq(shard_version)
      compiled_version({"CRYSTALRELEASER_VERSION" => ""}).should eq(shard_version)
    end
  end

  describe "NAME" do
    it "is the shard name" do
      Crystalreleaser::NAME.should eq("crystalreleaser")
    end
  end

  describe "TARGET" do
    it "is the os/arch the binary was compiled for" do
      Crystalreleaser::TARGET.should match(%r{\A(linux|darwin|freebsd|windows|unknown)/(amd64|arm64|unknown)\z})
    end
  end

  describe ".commit" do
    it "is a short ref, optionally suffixed -dirty, or unknown" do
      Crystalreleaser.commit.should match(/\A(unknown|[0-9a-f]{8}(-dirty)?)\z/)
    end
  end

  describe ".version_line" do
    it "names the program, then version, commit and target" do
      Crystalreleaser.version_line.should match(
        %r{\Acrystalreleaser \S+ \((unknown|[0-9a-f]{8}(-dirty)?), [a-z]+/[a-z0-9]+\)\z}
      )
    end
  end
end
