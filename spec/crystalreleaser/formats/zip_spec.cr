require "compress/zip"
require "../../spec_helper"

private MTIME = Time.utc(2026, 11, 1, 12, 0, 0)

private def build_zip(dir : String) : Bytes
  File.write(File.join(dir, "toy"), "#!/bin/sh\necho toy\n")
  File.write(File.join(dir, "LICENSE"), "MIT\n")
  io = IO::Memory.new
  zip = Crystalreleaser::Formats::Zip::Writer.new(io)
  zip.add_directory("toy_1.0.0/", 0o755, MTIME)
  zip.add_file("toy_1.0.0/toy", 0o755, MTIME, File.join(dir, "toy"))
  zip.add_file("toy_1.0.0/LICENSE", 0o644, MTIME, File.join(dir, "LICENSE"))
  zip.close
  io.to_slice
end

private def with_zip(& : Bytes, String ->) : Nil
  dir = File.join(Dir.tempdir, "crystalreleaser-zip-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield build_zip(dir), dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# The external attributes of each central directory entry, by name
# (APPNOTE 4.3.12: 4 bytes at offset 38 of the header, name at offset 46).
private def external_attributes(bytes : Bytes) : Hash(String, UInt32)
  result = {} of String => UInt32
  io = IO::Memory.new(bytes)
  (0..bytes.size - 46).each do |offset|
    next unless bytes[offset, 4] == Bytes[0x50, 0x4b, 0x01, 0x02]
    io.pos = offset + 28
    name_size = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
    io.pos = offset + 38
    attributes = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    result[String.new(bytes[offset + 46, name_size])] = attributes
  end
  result
end

describe Crystalreleaser::Formats::Zip do
  it "is read back by the stdlib reader: names, content and the given time" do
    with_zip do |bytes|
      Compress::Zip::File.open(IO::Memory.new(bytes)) do |zip|
        zip.entries.map(&.filename).should eq(["toy_1.0.0/", "toy_1.0.0/toy", "toy_1.0.0/LICENSE"])
        zip["toy_1.0.0/toy"].open(&.gets_to_end).should eq("#!/bin/sh\necho toy\n")
        zip["toy_1.0.0/LICENSE"].open(&.gets_to_end).should eq("MIT\n")
        zip.entries.map(&.time).uniq!.should eq([MTIME])
      end
    end
  end

  it "stores the Unix mode of files and directories, executable bit included" do
    with_zip do |bytes|
      external_attributes(bytes).should eq({
        "toy_1.0.0/"        => (0o040755_u32 << 16) | 0x10_u32,
        "toy_1.0.0/toy"     => 0o100755_u32 << 16,
        "toy_1.0.0/LICENSE" => 0o100644_u32 << 16,
      })
    end
  end

  it "ends with a record locating the central directory exactly" do
    with_zip do |bytes|
      # APPNOTE 4.3.16: the last 22 bytes; directory size at 12, offset at 16.
      record = IO::Memory.new(bytes[bytes.size - 22, 22])
      record.read_bytes(UInt32, IO::ByteFormat::LittleEndian).should eq(0x06054b50_u32)
      record.pos = 12
      size = record.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      offset = record.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      (offset + size + 22).should eq(bytes.size)
      bytes[offset, 4].should eq(Bytes[0x50, 0x4b, 0x01, 0x02])
    end
  end

  # 65 535 is not a count in a zip without zip64: it is the value that says
  # "look in the zip64 record", which this writer does not write.
  it "holds 65 534 entries and refuses the 65 535th" do
    zip = Crystalreleaser::Formats::Zip::Writer.new(IO::Memory.new)
    65_534.times { |index| zip.add_directory("d#{index}/", 0o755, MTIME) }
    zip.close

    zip = Crystalreleaser::Formats::Zip::Writer.new(IO::Memory.new)
    65_535.times { |index| zip.add_directory("d#{index}/", 0o755, MTIME) }
    expect_raises(Crystalreleaser::FormatError, "too many entries for a zip archive without zip64") { zip.close }
  end

  it "produces identical bytes whenever it runs" do
    with_zip do |first, dir|
      sleep 2.1.seconds
      build_zip(dir).should eq(first)
    end
  end

  it "is extracted by unzip with the binary still executable" do
    pending_tool!("unzip")
    with_zip do |bytes, dir|
      File.write(File.join(dir, "toy.zip"), bytes)
      run_tool(["unzip", "-q", File.join(dir, "toy.zip"), "-d", File.join(dir, "out")])
      File.info(File.join(dir, "out/toy_1.0.0/toy")).permissions.value.should eq(0o755)
      File.info(File.join(dir, "out/toy_1.0.0/LICENSE")).permissions.value.should eq(0o644)
      File.read(File.join(dir, "out/toy_1.0.0/toy")).should eq("#!/bin/sh\necho toy\n")
    end
  end
end
