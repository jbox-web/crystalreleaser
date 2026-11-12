require "spec"

# Every library file; src/crystalreleaser.cr, the entry point, is left out.
require "../src/crystalreleaser/**"
require "./support/*"

# The toy projects the specs compile get a compiler cache of their own. With
# the shared ~/.cache/crystal, their compilers prune that cache while the spec
# binary, which lives in it, is still running, and a backtrace can then no
# longer be read from the executable.
SPEC_CRYSTAL_CACHE = File.join(Dir.tempdir, "crystalreleaser-spec-cache-#{Process.pid}")
ENV["CRYSTAL_CACHE_DIR"] = SPEC_CRYSTAL_CACHE
Spec.after_suite { FileUtils.rm_rf(SPEC_CRYSTAL_CACHE) }

# Examples tagged docker or cross need a docker daemon, or zig and a sysroot:
# excluded unless asked for with `crystal spec --tag docker` / `--tag cross`.
class Spec::CLI
  def requested_tags : Set(String)
    @tags || Set(String).new
  end
end

{"docker", "cross"}.each do |tag|
  Spec.cli.add_tag("~#{tag}") unless Spec.cli.requested_tags.includes?(tag)
end

# Result of an in-process CLI run: exit code plus everything written to the
# two streams. The CLI never calls `exit` itself, which is what makes it
# drivable from a spec without spawning the binary.
record CliRun, code : Int32, stdout : String, stderr : String

def run_cli(*args : String) : CliRun
  run_cli_with(args.to_a)
end

# A typed splat needs at least one argument, hence the bare overload.
def run_cli : CliRun
  run_cli_with([] of String)
end

def run_cli_with(args : Array(String), dir : String = Dir.current) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Crystalreleaser::CLI.new(stdout, stderr, dir).run(args)
  CliRun.new(code, stdout.to_s, stderr.to_s)
end

# Runs the CLI as if launched from `dir`, without changing the process
# working directory (specs may run on several threads).
def run_cli_in(dir : String, *args : String) : CliRun
  run_cli_with(args.to_a, dir)
end
