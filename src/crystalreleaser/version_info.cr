require "semantic_version"

require "./error"

module Crystalreleaser
  # The version being released, split into the parts templates expose.
  struct VersionInfo
    getter tag : String
    # The tag without its `v` prefix, pre-release included: `1.2.3-rc.1`.
    getter version : String
    # Major.Minor.Patch only: `1.2.3`.
    getter raw_version : String
    getter major : String
    getter minor : String
    getter patch : String
    getter prerelease : String
    getter? snapshot : Bool

    def initialize(@tag : String, semver : SemanticVersion, @snapshot : Bool)
      @version = semver.to_s
      @major = semver.major.to_s
      @minor = semver.minor.to_s
      @patch = semver.patch.to_s
      @raw_version = "#{@major}.#{@minor}.#{@patch}"
      @prerelease = semver.prerelease.to_s
    end

    def self.release(tag : String) : VersionInfo
      semver = parse(tag) || raise GitError.new("tag '#{tag}' is not a semver version")
      new(tag, semver, false)
    end

    # `<next patch of last_tag>-SNAPSHOT-<short commit>`, starting at 0.0.1
    # when the repository has no tag yet.
    def self.snapshot(last_tag : String?, short_commit : String) : VersionInfo
      base = last_tag.try { |tag| parse(tag) }
      major, minor, patch = base ? {base.major, base.minor, base.patch + 1} : {0, 0, 1}
      version = "#{major}.#{minor}.#{patch}-SNAPSHOT-#{short_commit}"
      new("v#{version}", SemanticVersion.parse(version), true)
    end

    # Parses `v1.2.3` or `1.2.3`, with an optional pre-release and build part.
    def self.parse(tag : String) : SemanticVersion?
      SemanticVersion.parse(tag.lchop('v'))
    rescue ArgumentError
      nil
    end
  end
end
