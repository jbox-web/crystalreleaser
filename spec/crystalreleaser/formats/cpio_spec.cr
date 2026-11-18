require "../../spec_helper"

private def with_file(content : String, & : String ->) : Nil
  path = File.join(Dir.tempdir, "crystalreleaser-cpio-#{Random::Secure.hex(6)}")
  File.write(path, content)
  yield path
ensure
  File.delete?(path) if path
end

describe Crystalreleaser::Formats::Cpio do
  it "writes newc headers, 4-byte padding and the trailer" do
    with_file("hello") do |path|
      io = IO::Memory.new
      cpio = Crystalreleaser::Formats::Cpio::Writer.new(io)
      cpio.add_file("./usr/bin/toy", 0o755, Time.unix(1_700_000_000), path)
      cpio.close

      # ino 1, mode 0100755 (81ed), uid 0, gid 0, nlink 1, mtime 6553f100,
      # size 5, four device numbers 0, name size 14, check 0.
      io.to_s.should eq(
        "070701" \
        "00000001000081ed000000000000000000000001" \
        "6553f10000000005" \
        "00000000000000000000000000000000" \
        "0000000e00000000" \
        "./usr/bin/toy\0" \
        "hello\0\0\0" \
        "070701" \
        "00000000000000000000000000000000000000010000000000000000" \
        "00000000000000000000000000000000" \
        "0000000b00000000" \
        "TRAILER!!!\0\0\0\0")
      cpio.written.should eq(io.size)
    end
  end

  # A newc field is 8 hexadecimal digits: a ninth would shift every field
  # after it.
  it "refuses a time its 8-digit field cannot hold" do
    {Time.utc(2200, 1, 1), Time.utc(1969, 12, 31)}.each do |time|
      writer = Crystalreleaser::Formats::Cpio::Writer.new(IO::Memory.new)
      expect_raises(Crystalreleaser::FormatError, "a cpio archive cannot hold a date before 1970 or after 2106") do
        writer.add_directory("./usr", 0o755, time)
      end
    end
  end

  it "reads back what it wrote" do
    with_file("MIT\n") do |path|
      io = IO::Memory.new
      cpio = Crystalreleaser::Formats::Cpio::Writer.new(io)
      cpio.add_file("./a", 0o644, Time.unix(5), path)
      cpio.add_file("./b/c", 0o755, Time.unix(6), path)
      cpio.close

      Crystalreleaser::Formats::Cpio.read(IO::Memory.new(io.to_slice))
        .map { |entry| {entry.name, entry.mode, entry.ino, entry.mtime.to_unix, String.new(entry.content)} }
        .should eq([{"./a", 0o100644, 1, 5, "MIT\n"}, {"./b/c", 0o100755, 2, 6, "MIT\n"}])
    end
  end

  # newc stores a symbolic link as an entry of type 0120000 whose data is the
  # target, its size the target's length: what rpmbuild writes in a payload.
  it "writes a symbolic link: mode 0120777, the target as its data" do
    io = IO::Memory.new
    cpio = Crystalreleaser::Formats::Cpio::Writer.new(io)
    cpio.add_symlink("./usr/bin/toy-manager", "toy", Time.unix(1_700_000_000))

    # ino 1, mode 0120777 (a1ff), uid 0, gid 0, nlink 1, mtime 6553f100,
    # size 3, four device numbers 0, name size 22 (16), check 0.
    io.to_s.should eq(
      "070701" \
      "000000010000a1ff000000000000000000000001" \
      "6553f10000000003" \
      "00000000000000000000000000000000" \
      "0000001600000000" \
      "./usr/bin/toy-manager\0" \
      "toy\0")
    cpio.written.should eq(io.size)
  end

  it "lists a symbolic link with the system cpio as a link to its target" do
    pending_tool!("cpio")
    io = IO::Memory.new
    cpio = Crystalreleaser::Formats::Cpio::Writer.new(io)
    cpio.add_symlink("./usr/bin/toy-manager", "toy", Time.unix(1_700_000_000))
    cpio.close
    output = IO::Memory.new
    Process.run("cpio", ["-itv"], input: IO::Memory.new(io.to_slice), output: output, error: Process::Redirect::Close)
      .success?.should be_true
    line = output.to_s.lines.first
    line.should start_with("lrwxrwxrwx")
    line.should end_with("./usr/bin/toy-manager -> toy")
  end

  it "is listed by the system cpio" do
    pending_tool!("cpio")
    with_file("hello") do |path|
      io = IO::Memory.new
      cpio = Crystalreleaser::Formats::Cpio::Writer.new(io)
      cpio.add_file("./usr/bin/toy", 0o755, Time.unix(1_700_000_000), path)
      cpio.close
      output = IO::Memory.new
      Process.run("cpio", ["-it"], input: IO::Memory.new(io.to_slice), output: output, error: Process::Redirect::Close)
        .success?.should be_true
      output.to_s.lines.should eq(["./usr/bin/toy"])
    end
  end
end
