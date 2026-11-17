# A package spec over two real files in `dir`: a binary and a licence.
def sample_package(dir : String) : Crystalreleaser::Formats::PackageSpec
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "toy"), "#!/bin/sh\necho toy\n")
  File.write(File.join(dir, "LICENSE"), "MIT\n")
  spec = Crystalreleaser::Formats::PackageSpec.new("toy", "1.2.3-rc.1", "amd64")
  spec.maintainer = "Jane Doe <jane@example.com>"
  spec.description = "A toy\nIt prints its name.\n\nThat is all."
  spec.homepage = "https://example.com/toy"
  spec.license = "MIT"
  spec.vendor = "jbox-web"
  spec.dependencies = ["libc6", "ca-certificates"]
  spec.mtime = Time.unix(1_700_000_000)
  spec.files = [
    Crystalreleaser::Formats::PackageSpec::File.new("/usr/bin/toy", File.join(dir, "toy"), 0o755),
    Crystalreleaser::Formats::PackageSpec::File.new("/usr/share/doc/toy/LICENSE", File.join(dir, "LICENSE"), 0o644),
  ]
  spec
end

def tool?(name : String) : Bool
  !Process.find_executable(name).nil?
end

def run_tool(args : Array(String)) : String
  status, output = Crystalreleaser::Subprocess.run(args[0], args[1..])
  raise "#{args.join(' ')} failed:\n#{output}" unless status.success?
  output
end

# Marks the example pending off macOS: otool, and the Homebrew libraries a
# darwin binary must not depend on, only exist there. SPEC_REQUIRE_TOOLS does
# not apply: `all` on a linux runner must not fail these examples.
def pending_unless_macos! : Nil
  {% unless flag?(:darwin) %}
    pending!("macOS only")
  {% end %}
end

# Marks the example pending when the Homebrew formula is not installed, or
# fails it when SPEC_REQUIRE_TOOLS names the formula (or says `all`). Returns
# the formula's prefix.
def pending_homebrew!(formula : String) : String
  if prefix = Crystalreleaser::Builders::Native.brew_prefix(formula)
    return prefix
  end
  required = ENV.fetch("SPEC_REQUIRE_TOOLS", "").split(',').map(&.strip)
  raise "#{formula} is required by SPEC_REQUIRE_TOOLS but Homebrew has it not" if required.includes?(formula) || required.includes?("all")
  pending!("Homebrew has no #{formula}")
end

# Marks the example pending when a system tool the spec checks its output
# with is missing. These tools are the only judges of the hand-written formats
# that are not this code itself, so a run that must not go without them lists
# them in SPEC_REQUIRE_TOOLS (comma-separated, or `all`): a missing one then
# fails the example instead of leaving it pending.
def pending_tool!(name : String) : Nil
  return if tool?(name)
  required = ENV.fetch("SPEC_REQUIRE_TOOLS", "").split(',').map(&.strip)
  raise "#{name} is required by SPEC_REQUIRE_TOOLS but is not installed" if required.includes?(name) || required.includes?("all")
  pending!("#{name} is not installed")
end
