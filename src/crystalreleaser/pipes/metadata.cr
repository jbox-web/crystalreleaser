require "json"

require "../artifact"
require "../context"
require "../pipe"
require "./checksum"

module Crystalreleaser
  module Pipes
    # dist/artifacts.json (every artifact, with its sha256) and
    # dist/metadata.json (the release facts), for CI steps and for the merge
    # of a split build.
    class Metadata < Pipe
      def name : String
        "metadata"
      end

      def description : String
        "writing metadata"
      end

      def run(ctx : Context) : Nil
        artifacts = ctx.artifacts.all
        artifacts.each do |artifact|
          artifact.sha256 ||= Checksum.sha256(File.join(ctx.dir, artifact.path))
        end
        File.write(ctx.dist_path("artifacts.json"), artifacts.to_pretty_json + "\n")
        File.write(ctx.dist_path("metadata.json"), metadata(ctx).to_pretty_json + "\n")
        ctx.logger.info("artifacts.json")
        ctx.logger.info("metadata.json")
      end

      private def metadata(ctx : Context)
        info = ctx.version_info
        {
          project_name: ctx.config.project_name,
          tag:          info.tag,
          previous_tag: ctx.previous_tag,
          version:      info.version,
          commit:       ctx.commit,
          date:         ctx.now.to_utc.to_rfc3339,
          snapshot:     info.snapshot?,
        }
      end
    end
  end
end
