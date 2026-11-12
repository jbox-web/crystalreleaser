require "../context"
require "../git"
require "../pipe"
require "../version_info"

module Crystalreleaser
  module Pipes
    # Reads the version and commit facts. A release needs a clean tree and
    # exactly one semver tag on HEAD; a snapshot needs neither and versions
    # itself after the next patch of the last tag.
    class Git < Pipe
      def name : String
        "git"
      end

      def description : String
        "getting git state"
      end

      def skippable? : Bool
        false
      end

      def run(ctx : Context) : Nil
        git = Crystalreleaser::Git.new(ctx.dir)
        short = git.short_commit
        if ctx.options.snapshot?
          last = git.last_tag
          if last.nil? && git.shallow?
            ctx.logger.warn("this is a shallow clone and no version tag is in reach: the snapshot version starts " \
                            "from 0.0.0; fetch the full history (actions/checkout: fetch-depth: 0)")
          end
          ctx.version_info = VersionInfo.snapshot(last, short)
          ctx.previous_tag = last
        else
          status = git.status
          unless status.empty?
            changes = status.lines.first(20).join('\n') { |line| "  #{line}" }
            raise GitError.new("git is in a dirty state, commit or stash these changes, or use --snapshot:\n#{changes}")
          end
          tag = git.current_tag
          ctx.version_info = VersionInfo.release(tag)
          ctx.previous_tag = git.previous_tag(tag)
        end
        ctx.commit = git.commit
        ctx.short_commit = short
        ctx.branch = git.branch
        ctx.commit_time = git.commit_time

        ctx.logger.info("version #{ctx.version_info.version}", tag: ctx.version_info.tag,
          previous: ctx.previous_tag || "none", commit: short)
        check_shard_version(ctx)
      end

      private def check_shard_version(ctx : Context) : Nil
        return if ctx.snapshot?
        shard_version = ctx.config.shard_version
        version = ctx.version_info.version
        return if shard_version.empty? || shard_version == version
        ctx.logger.warn("shard.yml version #{shard_version} does not match the tag version #{version}")
      end
    end
  end
end
