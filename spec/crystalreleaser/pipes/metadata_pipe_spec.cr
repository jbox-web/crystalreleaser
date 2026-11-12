require "../../spec_helper"

describe Crystalreleaser::Pipes::Metadata do
  it "writes artifacts.json with a sha256 for every artifact" do
    Fixture.project do |project|
      ctx = spec_context(project)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Metadata.new.run(ctx)

      artifacts = JSON.parse(File.read(project.path("dist/artifacts.json"))).as_a
      artifacts.size.should eq(1)
      binary = artifacts.first
      {binary["type"], binary["name"], binary["path"], binary["os"], binary["arch"]}
        .should eq({"binary", "toy", "dist/toy_linux_amd64/toy", "linux", "amd64"})
      # printf 'toy for linux/amd64' | sha256sum
      binary["sha256"].should eq("0d5a510f5b2985789a455a09ac2ab7680af4fe849636c69938782cd03325c083")
    end
  end

  it "writes metadata.json with the release facts" do
    Fixture.project do |project|
      ctx = spec_context(project)
      Dir.mkdir_p(ctx.dist_path)
      Crystalreleaser::Pipes::Metadata.new.run(ctx)

      JSON.parse(File.read(project.path("dist/metadata.json"))).should eq(JSON.parse(<<-JSON))
        {
          "project_name": "toy",
          "tag": "v1.2.3-rc.1",
          "previous_tag": "v1.2.2",
          "version": "1.2.3-rc.1",
          "commit": "0123456789abcdef0123456789abcdef01234567",
          "date": "2026-11-12T08:30:00Z",
          "snapshot": false
        }
        JSON
    end
  end
end
