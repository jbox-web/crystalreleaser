require "../../spec_helper"

private CONFIG = <<-YAML
  builds:
    - id: toy
      target: toy
      platforms:
        - os: linux
          arch: amd64
          strategy: docker
          static: true
  YAML

# What `build --split` leaves on a runner, written by hand: the binary, its
# artifacts.json and the metadata.json of the folder. The blocks change one
# of them before the merge.
private def split_build(project : Fixture::Project, artifact : Hash(String, JSON::Any)? = nil,
                        metadata : String? = nil) : Crystalreleaser::Context
  options = Crystalreleaser::Options.new
  options.merge = true
  ctx = spec_context(project, options: options)
  binary = ctx.dist_path("linux_amd64", "toy_linux_amd64", "toy")
  Dir.mkdir_p(File.dirname(binary))
  File.write(binary, "toy for linux/amd64")
  entry = {
    "type" => "binary", "name" => "toy", "path" => "dist/linux_amd64/toy_linux_amd64/toy", "os" => "linux",
    "arch" => "amd64", "build_id" => "toy", "size" => 19, "extra" => {"target" => "x86_64-linux-musl"},
    "sha256" => Crystalreleaser::Pipes::Checksum.sha256(binary),
  }
  entry = JSON.parse(entry.to_json).as_h
  artifact.try { |changes| entry.merge!(changes) }
  File.write(ctx.dist_path("linux_amd64", "artifacts.json"), [entry].to_json)
  File.write(ctx.dist_path("linux_amd64", "metadata.json"), metadata || {
    version: "1.2.3-rc.1", tag: "v1.2.3-rc.1", commit: ctx.commit, os: "linux", arch: "amd64",
  }.to_json)
  ctx
end

private def merge_error(ctx : Crystalreleaser::Context) : String
  error = expect_raises(Crystalreleaser::BuildError) { Crystalreleaser::Pipes::Merge.new.run(ctx) }
  error.message.to_s
end

describe Crystalreleaser::Pipes::Merge do
  it "registers the binaries of a split build" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project)
      Crystalreleaser::Pipes::Merge.new.run(ctx)
      ctx.artifacts.all.map { |artifact| {artifact.type, artifact.name, artifact.path, artifact.os, artifact.arch} }.should eq([
        {Crystalreleaser::Artifact::Type::Binary, "toy", "dist/linux_amd64/toy_linux_amd64/toy", "linux", "amd64"},
      ])
    end
  end

  it "fails when dist/ holds no split build" do
    Fixture.project(config: CONFIG) do |project|
      options = Crystalreleaser::Options.new
      options.merge = true
      ctx = spec_context(project, options: options)
      Dir.mkdir_p(ctx.dist_path)
      merge_error(ctx).should eq("no split build found: expected dist/<os>_<arch>/artifacts.json")
    end
  end

  # The project path is not a pattern.
  it "finds the split builds of a project whose path holds glob characters" do
    Fixture.project(config: CONFIG) do |outer|
      nested = Fixture::Project.new(outer.path("proj[1]"))
      nested.write("shard.yml", File.read(outer.path("shard.yml")))
      nested.write("src/toy.cr", File.read(outer.path("src/toy.cr")))
      nested.write(".crystalreleaser.yml", CONFIG)
      ctx = split_build(nested)
      Crystalreleaser::Pipes::Merge.new.run(ctx)
      ctx.artifacts.all.size.should eq(1)
    end
  end

  it "refuses a split build of another version" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project, metadata: %({"version": "9.9.9", "commit": "0123456789abcdef0123456789abcdef01234567"}))
      merge_error(ctx).should eq("dist/linux_amd64 was built as version 9.9.9, this release is 1.2.3-rc.1")
    end
  end

  {"null", "[]", %("text")}.each do |content|
    it "reports a metadata.json that is #{content} without a backtrace" do
      Fixture.project(config: CONFIG) do |project|
        ctx = split_build(project, metadata: content)
        merge_error(ctx).should eq("cannot read the split build in dist/linux_amd64: metadata.json is not an object")
      end
    end
  end

  it "refuses a binary that is listed but missing" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project)
      File.delete(ctx.dist_path("linux_amd64", "toy_linux_amd64", "toy"))
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy is listed but missing")
    end
  end

  # The size alone would let through a file changed in transit that kept its
  # length.
  it "refuses a binary whose content is not the one its runner recorded" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project)
      File.write(ctx.dist_path("linux_amd64", "toy_linux_amd64", "toy"), "TOY FOR LINUX/AMD64")
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy does not have the sha256 its runner recorded")
    end
  end

  it "refuses a binary recorded without a sha256" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project, {"sha256" => JSON::Any.new(nil)})
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy has no sha256 recorded")
    end
  end

  it "refuses anything that is not a binary" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project, {"type" => JSON::Any.new("archive")})
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy is recorded as archive, not as a binary")
    end
  end

  it "refuses a binary recorded for another platform than its folder" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project, {"arch" => JSON::Any.new("arm64")})
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy is recorded for linux/arm64 in a linux/amd64 build")
    end
  end

  it "refuses a binary name that is not a plain name" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project, {"name" => JSON::Any.new("../toy")})
      merge_error(ctx).should eq(%(dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy is named "../toy", which is not a plain name))
    end
  end

  # The path check is on the text of the path: a link inside the folder may
  # lead anywhere, and chmod follows it.
  it "refuses a symbolic link, without touching what it points to" do
    Fixture.project(config: CONFIG) do |project|
      ctx = split_build(project)
      binary = ctx.dist_path("linux_amd64", "toy_linux_amd64", "toy")
      File.delete(binary)
      File.chmod(project.path("shard.yml"), 0o644)
      File.symlink(project.path("shard.yml"), binary)
      merge_error(ctx).should eq("dist/linux_amd64: dist/linux_amd64/toy_linux_amd64/toy is a symbolic link")
      File.info(project.path("shard.yml")).permissions.value.should eq(0o644)
    end
  end
end
