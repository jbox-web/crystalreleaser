require "../spec_helper"

private def binary(os : String, arch : String, build_id = "toy") : Crystalreleaser::Artifact
  Crystalreleaser::Artifact.new(
    Crystalreleaser::Artifact::Type::Binary, "toy", "dist/#{build_id}_#{os}_#{arch}/toy",
    os: os, arch: arch, build_id: build_id, size: 42_i64)
end

describe Crystalreleaser::ArtifactRegistry do
  it "returns artifacts in insertion order and filters them" do
    registry = Crystalreleaser::ArtifactRegistry.new
    registry.add(binary("linux", "amd64"))
    registry.add(binary("darwin", "arm64"))
    registry.add(binary("linux", "arm64", "other"))

    registry.all.map(&.path).should eq([
      "dist/toy_linux_amd64/toy", "dist/toy_darwin_arm64/toy", "dist/other_linux_arm64/toy",
    ])
    registry.filter(os: "linux").map(&.path).should eq(["dist/toy_linux_amd64/toy", "dist/other_linux_arm64/toy"])
    registry.filter(build_id: "other").map(&.arch).should eq(["arm64"])
    registry.filter(type: Crystalreleaser::Artifact::Type::Archive).should be_empty
  end

  it "accepts concurrent additions without losing any" do
    registry = Crystalreleaser::ArtifactRegistry.new
    done = Channel(Nil).new
    50.times do |index|
      spawn do
        registry.add(binary("linux", "amd64", "b#{index}"))
        done.send(nil)
      end
    end
    50.times { done.receive }
    registry.all.size.should eq(50)
  end

  it "serialises an artifact to JSON with its type in snake case" do
    JSON.parse(binary("linux", "amd64").to_json).should eq(JSON.parse(<<-JSON))
      {"type": "binary", "name": "toy", "path": "dist/toy_linux_amd64/toy",
       "os": "linux", "arch": "amd64", "build_id": "toy", "size": 42, "extra": {}}
      JSON
  end
end
