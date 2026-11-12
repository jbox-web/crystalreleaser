# Version and build provenance, adapted from the canonical version.cr template.
#
# The one deliberate difference: VERSION is first read from the
# CRYSTALRELEASER_VERSION environment variable at compile time. That is the
# version-injection pattern crystalreleaser documents for every Crystal project
# (Crystal has no `-ldflags -X`), applied to itself: the release build exports
# CRYSTALRELEASER_VERSION={{ .Version }} through the `env:` of its build config.
# Outside a release the shard version is used, as in the template.
#
# WHY EVERY BACKTICK IS ANCHORED (`git -C`, `shards version <dir>`)
#   A macro backtick runs the command in the COMPILER's working directory, not
#   in the source file's directory. `-C "#{__DIR__}"` anchors it on this tree, and
#   degrades to "unknown" when there is no repository. The path is quoted: a
#   checkout under a directory with a space in its name must still compile.
module Crystalreleaser
  # A variable that is set but empty (a CI expression that expanded to nothing)
  # is not a version.
  VERSION = {{ (env("CRYSTALRELEASER_VERSION") || "").empty? ? `shards version "#{__DIR__}"`.chomp.stringify : env("CRYSTALRELEASER_VERSION") }}
  # Read from shard.yml rather than written down a second time: a literal
  # would be free to drift from the shard, and nothing would catch it.
  NAME = {{ read_file("#{__DIR__}/../../shard.yml").lines.find(&.starts_with?("name:")).split(":")[1].strip }}
  # `|| true` because the build is not always a git checkout: a source tarball
  # has no repository, git prints nothing, and without the fallback the version
  # string reads "1.0.0 ()" in every bug report quoting it.
  GIT_REF = {{ `git -C "#{__DIR__}" log -n 1 --format="%H" 2>/dev/null | head -c 8 || true`.chomp.stringify }}
  # Non-empty when the working tree carried uncommitted changes at compile
  # time: without it, a binary built from patched sources reports the exact
  # string the pristine release reports.
  GIT_DIRTY = {{ `git -C "#{__DIR__}" status --porcelain 2>/dev/null | head -c 1 || true`.chomp.stringify }}
  # The nearest tag and the distance to it ("v1.2.0-4-gd86b19d8"). Empty
  # outside a checkout, and in a repository with no tag at all.
  GIT_TAG = {{ `git -C "#{__DIR__}" describe --tags 2>/dev/null || true`.chomp.stringify }}
  # Compile timestamp, UTC and ISO 8601. POSIX syntax, so it behaves the same
  # under busybox in an Alpine builder and under GNU date.
  BUILT_AT = {{ `date -u +%Y-%m-%dT%H:%M:%SZ`.chomp.stringify }}
  # The platform this binary was compiled for, from the compiler's own flags
  # and NOT from `Crystal::DESCRIPTION`, whose "Default target" is the
  # compiler's own and would lie under cross-compilation.
  TARGET = {{ flag?(:linux) ? "linux" : (flag?(:darwin) ? "darwin" : (flag?(:freebsd) ? "freebsd" : (flag?(:windows) ? "windows" : "unknown"))) }} +
           "/" + {{ flag?(:x86_64) ? "amd64" : (flag?(:aarch64) ? "arm64" : "unknown") }}

  # The short ref, suffixed `-dirty` when the tree was patched, and "unknown"
  # when there was no repository to ask.
  def self.commit : String
    return "unknown" if GIT_REF.empty?
    GIT_DIRTY.empty? ? GIT_REF : "#{GIT_REF}-dirty"
  end

  # The nearest git tag, or "unknown".
  def self.git_tag : String
    GIT_TAG.empty? ? "unknown" : GIT_TAG
  end

  # The provenance on its own — version, commit, platform, NO program name.
  def self.version : String
    "#{VERSION} (#{commit}, #{TARGET})"
  end

  # The self-describing one-liner behind `--version`:
  #
  #   crystalreleaser 0.1.0 (d86b19d8-dirty, linux/amd64)
  def self.version_line : String
    "#{NAME} #{version}"
  end
end
