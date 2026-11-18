require "json"

module Crystalreleaser
  # A file the pipeline produced: a binary, an archive, a package... Paths are
  # relative to the project directory, which keeps artifacts.json portable
  # between the machines of a split build.
  class Artifact
    include JSON::Serializable

    enum Type
      Binary
      Archive
      Checksum
      LinuxPackage
      Formula
      AquaRegistry
      # The public half of a key packages were signed with.
      PublicKey

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s.underscore)
      end
    end

    getter type : Type
    getter name : String
    getter path : String
    getter os : String?
    getter arch : String?
    getter build_id : String?
    getter size : Int64?
    # Free-form facts a later pipe needs (sha256, format, target triple...).
    getter extra : Hash(String, String)
    # Filled by the checksum pipe for what it hashes, and by the metadata
    # pipe for everything else.
    property sha256 : String? = nil

    def initialize(@type : Type, @name : String, @path : String, *,
                   @os : String? = nil, @arch : String? = nil, @build_id : String? = nil,
                   @size : Int64? = nil, @extra : Hash(String, String) = {} of String => String)
    end
  end

  # Every artifact of the run. Builds run on parallel fibers, possibly on
  # several threads (-Dpreview_mt), hence the mutex.
  class ArtifactRegistry
    def initialize
      @artifacts = [] of Artifact
      @mutex = Mutex.new
    end

    def add(artifact : Artifact) : Nil
      @mutex.synchronize { @artifacts << artifact }
    end

    # A snapshot copy, in insertion order.
    def all : Array(Artifact)
      @mutex.synchronize { @artifacts.dup }
    end

    def filter(*, type : Artifact::Type? = nil, os : String? = nil, arch : String? = nil, build_id : String? = nil) : Array(Artifact)
      all.select do |artifact|
        (type.nil? || artifact.type == type) &&
          (os.nil? || artifact.os == os) &&
          (arch.nil? || artifact.arch == arch) &&
          (build_id.nil? || artifact.build_id == build_id)
      end
    end
  end
end
