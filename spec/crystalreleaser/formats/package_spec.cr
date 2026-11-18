require "../../spec_helper"

private alias PackageFile = Crystalreleaser::Formats::PackageSpec::File

describe Crystalreleaser::Formats::PackageSpec do
  it "holds a symbolic link as a file entry: its destination and its target, no source" do
    link = PackageFile.symlink("/usr/bin/donico-manager", "donico")
    {link.dst, link.link, link.symlink?, link.src, link.mode, link.kind}
      .should eq({"/usr/bin/donico-manager", "donico", true, "", 0o777, Crystalreleaser::Formats::PackageSpec::Kind::Regular})
    PackageFile.new("/usr/bin/donico", "/tmp/donico", 0o755).symlink?.should be_false
  end

  # A symbolic link has no source file to measure, and takes no room.
  it "counts no size for a symbolic link, and the directories leading to it" do
    dir = File.join(Dir.tempdir, "crystalreleaser-package-#{Random::Secure.hex(6)}")
    begin
      spec = sample_package(dir)
      spec.files << PackageFile.symlink("/usr/libexec/toy/toy-manager", "../../bin/toy")
      # "#!/bin/sh\necho toy\n" (19 bytes) and "MIT\n" (4 bytes).
      spec.installed_size.should eq(23)
      spec.directories.should contain("/usr/libexec/toy")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
