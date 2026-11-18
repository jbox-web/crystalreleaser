require "../../spec_helper"

private MTIME = Time.unix(1_700_000_000)

private def gnu_tar? : Bool
  output = IO::Memory.new
  Process.run("tar", ["--version"], output: output, error: Process::Redirect::Close).success? &&
    output.to_s.includes?("GNU tar")
rescue File::NotFoundError
  false
end

private def build_tar(& : Crystalreleaser::Formats::Tar::Writer ->) : Bytes
  io = IO::Memory.new
  writer = Crystalreleaser::Formats::Tar::Writer.new(io)
  yield writer
  writer.close
  io.to_slice
end

describe Crystalreleaser::Formats::Tar do
  it "refuses a time before 1970, which the octal field cannot hold" do
    expect_raises(Crystalreleaser::FormatError, "a tar archive cannot hold a time before 1970: bin/toy") do
      build_tar { |tar| tar.add_file("bin/toy", 0o755, Time.unix(-1), "x".to_slice) }
    end
  end

  it "writes a directory and a file, then two zero blocks" do
    bytes = build_tar do |tar|
      tar.add_directory("bin", MTIME)
      tar.add_file("bin/toy", 0o755, MTIME, "hello".to_slice)
    end

    # header + header + one data block + two end blocks
    bytes.size.should eq(512 * 5)
    String.new(bytes[0, 4]).should eq("bin/")
    bytes[156].chr.should eq('5')
    String.new(bytes[512, 7]).should eq("bin/toy")
    bytes[512 + 156].chr.should eq('0')
    String.new(bytes[1024, 5]).should eq("hello")
    bytes[1536, 1024].all?(&.zero?).should be_true
  end

  # ustar: typeflag at 156, linkname at 157 (100 bytes), size at 124, mode at
  # 100; a symbolic link carries no data block.
  it "writes a symbolic link: typeflag 2, the target in the link field, size 0, mode 0777" do
    bytes = build_tar { |tar| tar.add_symlink("donico-manager", "donico", MTIME) }

    # one header + two end blocks
    bytes.size.should eq(512 * 3)
    String.new(bytes[0, 14]).should eq("donico-manager")
    bytes[156].chr.should eq('2')
    String.new(bytes[157, 6]).should eq("donico")
    bytes[163, 94].all?(&.zero?).should be_true
    String.new(bytes[124, 12]).should eq("00000000000\0")
    String.new(bytes[100, 8]).should eq("0000777\0")
  end

  it "refuses a symbolic link target that does not fit the 100 bytes of the link field" do
    expect_raises(Crystalreleaser::FormatError, "tar field overflow") do
      build_tar(&.add_symlink("l", "t" * 101, MTIME))
    end
  end

  it "reads back what it wrote" do
    bytes = build_tar do |tar|
      tar.add_directory("pkg", MTIME)
      tar.add_file("pkg/LICENSE", 0o644, MTIME, "MIT\n".to_slice)
    end
    entries = Crystalreleaser::Formats::Tar.read(IO::Memory.new(bytes))

    entries.map { |entry| {entry.name, entry.mode, entry.type, entry.uid, entry.uname, entry.mtime, String.new(entry.content)} }
      .should eq([
        {"pkg/", 0o755, '5', 0, "root", MTIME, ""},
        {"pkg/LICENSE", 0o644, '0', 0, "root", MTIME, "MIT\n"},
      ])
  end

  it "splits a path longer than 100 bytes into the ustar prefix" do
    long = "#{"d" * 120}/#{"f" * 90}"
    bytes = build_tar { |tar| tar.add_file(long, 0o644, MTIME, Bytes.empty) }
    Crystalreleaser::Formats::Tar.read(IO::Memory.new(bytes)).first.name.should eq(long)
  end

  # Split at its first slash, an absolute path would lose it: the prefix
  # would be empty and the name relative.
  it "rejects an absolute path whose only split point is its first slash" do
    expect_raises(Crystalreleaser::FormatError, "path too long for a ustar archive") do
      Crystalreleaser::Formats::Tar.split_name("/" + "a" * 100)
    end
  end

  it "rejects a path that does not fit ustar" do
    expect_raises(Crystalreleaser::FormatError, "path too long for a ustar archive: #{"x" * 101}") do
      build_tar { |tar| tar.add_file("x" * 101, 0o644, MTIME, Bytes.empty) }
    end
  end

  it "is byte for byte what GNU tar writes for the same input" do
    pending!("GNU tar is not installed") unless gnu_tar?

    dir = File.join(Dir.tempdir, "crystalreleaser-tar-#{Random::Secure.hex(6)}")
    begin
      Dir.mkdir_p(File.join(dir, "in", "bin"))
      File.write(File.join(dir, "in", "bin", "toy"), "hello")
      File.chmod(File.join(dir, "in", "bin", "toy"), 0o755)
      File.chmod(File.join(dir, "in", "bin"), 0o755)
      status = Process.run("tar", [
        "--format=ustar", "--owner=root:0", "--group=root:0", "--mtime=@1700000000",
        "--record-size=512", "--no-recursion", "-cf", File.join(dir, "gnu.tar"), "bin", "bin/toy",
      ], chdir: File.join(dir, "in"))
      status.success?.should be_true

      ours = build_tar do |tar|
        tar.add_directory("bin", MTIME)
        tar.add_file("bin/toy", 0o755, MTIME, "hello".to_slice)
      end
      ours.should eq(File.read(File.join(dir, "gnu.tar")).to_slice)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "is listed by the system tar" do
    pending_tool!("tar")
    bytes = build_tar do |tar|
      tar.add_directory("bin", MTIME)
      tar.add_file("bin/toy", 0o755, MTIME, "hello".to_slice)
    end
    output = IO::Memory.new
    Process.run("tar", ["-tvf", "-"], input: IO::Memory.new(bytes), output: output).success?.should be_true
    lines = output.to_s.lines
    lines.size.should eq(2)
    lines[1].should start_with("-rwxr-xr-x")
    lines[1].should contain("root")
    lines[1].should end_with("bin/toy")
  end
end
