require "../../spec_helper"

describe Crystalreleaser::Formats::Ar do
  it "pads a member name to 16 bytes, not 16 characters" do
    io = IO::Memory.new
    Crystalreleaser::Formats::Ar::Writer.new(io).add("é.txt", "ab".to_slice, Time.unix(0))
    # magic (8) + header (60) + two bytes of content
    io.size.should eq(70)
    io.rewind
    Crystalreleaser::Formats::Ar.read(io).map(&.name).should eq(["é.txt"])
  end

  it "writes the signature and 60-byte text headers, padding odd members" do
    io = IO::Memory.new
    ar = Crystalreleaser::Formats::Ar::Writer.new(io)
    ar.add("debian-binary", "2.0\n".to_slice, Time.unix(1_700_000_000))
    ar.add("odd", "abc".to_slice, Time.unix(1_700_000_000))

    # Field by field: name 16, mtime 12, uid 6, gid 6, mode 8, size 10, "`\n".
    io.to_s.should eq(
      "!<arch>\n" \
      "debian-binary   1700000000  0     0     100644  4         `\n" \
      "2.0\n" \
      "odd             1700000000  0     0     100644  3         `\n" \
      "abc\n")
  end

  it "reads back what it wrote" do
    io = IO::Memory.new
    ar = Crystalreleaser::Formats::Ar::Writer.new(io)
    ar.add("a", "x".to_slice, Time.unix(10))
    ar.add("b.tar.gz", "yz".to_slice, Time.unix(20))
    members = Crystalreleaser::Formats::Ar.read(IO::Memory.new(io.to_slice))
    members.map { |member| {member.name, member.mtime.to_unix, member.mode, String.new(member.content)} }
      .should eq([{"a", 10, 0o100644, "x"}, {"b.tar.gz", 20, 0o100644, "yz"}])
  end

  it "rejects a member name longer than 16 bytes" do
    expect_raises(Crystalreleaser::FormatError, "ar member name longer than 16 bytes: a-very-long-member") do
      Crystalreleaser::Formats::Ar::Writer.new(IO::Memory.new).add("a-very-long-member", Bytes.empty, Time.unix(0))
    end
  end
end
