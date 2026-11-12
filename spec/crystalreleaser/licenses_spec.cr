require "../spec_helper"

describe Crystalreleaser::Licenses do
  # The list follows licenses.manifest: the upstream text of each library
  # whose license carries a copyright line of its own, one grouped file per
  # SPDX id for the others, plus the project's own LICENSE. An empty or
  # partial list means the harvest did not run before compilation.
  it "embeds the notices of the manifest plus the project license" do
    Crystalreleaser::Licenses::FILES.keys.should eq([
      "clib-Apache-2.0.txt",
      "clib-Boehm-GC.txt",
      "clib-GCC-runtime-exception.txt",
      "crystalreleaser.txt",
      "libyaml.txt",
      "musl.txt",
      "pcre2.txt",
      "zlib.txt",
    ])
  end

  it "records which libraries each grouped notice covers" do
    Crystalreleaser::Licenses::FILES["clib-Apache-2.0.txt"].should start_with("Used by: openssl, crystal\n")
  end

  # MIT, BSD and zlib all require the copyright notice to be reproduced: the
  # notice of the library, not the blank of a license template.
  it "carries the copyright notice of each library, as its authors wrote it" do
    files = Crystalreleaser::Licenses::FILES
    files["libyaml.txt"].should contain("Copyright (c) 2006-2016 Kirill Simonov")
    files["musl.txt"].should contain("Copyright © 2005-2020 Rich Felker, et al.")
    files["pcre2.txt"].should contain("University of Cambridge")
    files["zlib.txt"].should contain("Jean-loup Gailly and Mark Adler")
  end

  it "embeds no license template with its blanks left in" do
    Crystalreleaser::Licenses::FILES.each do |name, text|
      text.should_not match(/<year>|<owner>|<copyright holders>/), name
    end
  end
end
