require "semantic_version"

require "../context"
require "../pipe"

module Crystalreleaser
  module Pipes
    # Checks the host's crystal against the `crystal:` constraint of
    # shard.yml. A warning, not an error: docker builds use the image's
    # compiler, not the host's, and the constraint is often loose.
    class Shard < Pipe
      def name : String
        "shard"
      end

      def description : String
        "checking shard.yml"
      end

      def skip?(ctx : Context) : String?
        "no crystal constraint in shard.yml" if ctx.config.shard_crystal.empty?
      end

      def run(ctx : Context) : Nil
        constraint = ctx.config.shard_crystal
        version = ctx.crystal_version
        if version.empty?
          ctx.logger.warn("crystal not found, cannot check shard.yml crystal: #{constraint}")
        else
          case Shard.satisfies?(version, constraint)
          in true  then ctx.logger.info("crystal #{version} satisfies #{constraint}")
          in false then ctx.logger.warn("crystal #{version} does not satisfy shard.yml crystal: #{constraint}")
          in nil   then ctx.logger.warn("cannot read shard.yml crystal: #{constraint}")
          end
        end
      end

      # Shards constraint syntax: comma-separated `op version` parts, with
      # op one of >= > <= < = != ~>, a bare version meaning >= (shard.yml(5):
      # "x.y.z is interpreted as >= x.y.z"), and `*` anything. `~> 1.19`
      # means >= 1.19, < 2.0; `~> 1.20.0` means >= 1.20.0, < 1.21. A
      # pre-release suffix on the bound is accepted and ignored.
      #
      # Nil when the constraint cannot be read: that is not a mismatch.
      def self.satisfies?(version : String, constraint : String) : Bool?
        current = semver(version)
        constraint.split(',').map(&.strip).reject(&.empty?).all? do |part|
          next true if part == "*"
          match = part.match(/\A(>=|<=|~>|!=|>|<|=)?\s*(\d+(?:\.\d+){0,2})(?:-[0-9A-Za-z.-]+)?\z/)
          return unless match
          operator = match[1]? || ">="
          bound = semver(match[2])
          case operator
          when ">=" then current >= bound
          when ">"  then current > bound
          when "<=" then current <= bound
          when "<"  then current < bound
          when "="  then current == bound
          when "!=" then current != bound
          else           pessimistic?(current, match[2])
          end
        end
      end

      private def self.pessimistic?(current : SemanticVersion, written : String) : Bool
        parts = written.split('.').map(&.to_i)
        upper =
          if parts.size >= 3
            SemanticVersion.new(parts[0], parts[1] + 1, 0)
          else
            SemanticVersion.new(parts[0] + 1, 0, 0)
          end
        current >= semver(written) && current < upper
      end

      # Pads "1.19" to 1.19.0 and drops any pre-release, which the
      # comparison has no use for.
      private def self.semver(text : String) : SemanticVersion
        parts = text.split('-').first.split('.').map(&.to_i)
        (3 - parts.size).times { parts << 0 }
        SemanticVersion.new(parts[0], parts[1], parts[2])
      end
    end
  end
end
