require "compress/gzip"

# Members of a .tar.gz on disk.
def read_tar_gz(path : String) : Array(Crystalreleaser::Formats::Tar::Entry)
  File.open(path) do |file|
    Compress::Gzip::Reader.open(file) { |gzip| Crystalreleaser::Formats::Tar.read(gzip) }
  end
end

# Writes a fake binary under dist/ and registers it, as the build pipe would.
def fake_binary(ctx : Crystalreleaser::Context, os : String, arch : String, build_id = "toy", binary = "toy") : Nil
  path = ctx.dist_path("#{build_id}_#{os}_#{arch}", binary)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, "#{binary} for #{os}/#{arch}")
  ctx.artifacts.add(Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::Binary, binary, ctx.relative(path),
    os: os, arch: arch, build_id: build_id, size: File.size(path).to_i64,
    extra: {"target" => Crystalreleaser::Builders.triple(os, arch, false)}))
end
