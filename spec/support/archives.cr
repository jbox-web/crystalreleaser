require "compress/gzip"

# Members of a .tar.gz on disk.
def read_tar_gz(path : String) : Array(Crystalreleaser::Formats::Tar::Entry)
  File.open(path) do |file|
    Compress::Gzip::Reader.open(file) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
  end
end

# The 512-byte ustar header of the member `name` in a tar.gz, found by
# walking the blocks: each header is followed by the data blocks its size
# field (offset 124, octal) announces. Independent of the writer's helpers.
def tar_header(path : String, name : String) : Bytes
  io = IO::Memory.new
  File.open(path) { |file| Compress::Gzip::Reader.open(file) { |gzip| IO.copy(gzip, io) } }
  bytes = io.to_slice
  offset = 0
  while offset + 512 <= bytes.size
    header = bytes[offset, 512]
    break if header.all?(&.zero?)
    field = header[0, 100]
    return header.dup if String.new(field[0, field.index(0_u8) || 100]) == name
    size = String.new(header[124, 11]).to_i64(8)
    offset += 512 * (1 + (size + 511) // 512)
  end
  raise "no member #{name} in #{path}"
end

# Writes a fake binary under dist/ and registers it, as the build pipe would.
def fake_binary(ctx : Crystalreleaser::Context, os : String, arch : String, build_id = "toy", binary = "toy",
                aliases : Array(String) = [] of String) : Nil
  path = ctx.dist_path("#{build_id}_#{os}_#{arch}", binary)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, "#{binary} for #{os}/#{arch}")
  extra = {"target" => Crystalreleaser::Builders.triple(os, arch, false)}
  # As the build pipe records them: absent without aliases.
  extra["aliases"] = aliases.join(',') unless aliases.empty?
  ctx.artifacts.add(Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Binary, binary, ctx.relative(path),
    os: os, arch: arch, build_id: build_id, size: File.size(path).to_i64, extra: extra))
end
