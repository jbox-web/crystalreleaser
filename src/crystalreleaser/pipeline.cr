require "file_utils"

require "./context"
require "./error"
require "./git"
require "./pipe"
require "./pipes/*"

module Crystalreleaser
  # Runs pipes in order, after preparing the dist directory. Each pipe gets a
  # top-level log line and its own output is nested under it.
  class Pipeline
    def self.build : Pipeline
      new([
        Pipes::Validate.new,
        Pipes::Shard.new,
        Pipes::Git.new,
        Pipes::BeforeHooks.new,
        Pipes::Build.new,
      ] of Pipe)
    end

    # With `merge`, the binaries come from split builds instead of being
    # compiled, and the before hooks, meant for the build, do not run.
    def self.release(merge : Bool = false) : Pipeline
      produce = merge ? [Pipes::Merge.new] of Pipe : [Pipes::BeforeHooks.new, Pipes::Build.new] of Pipe
      new([
        Pipes::Validate.new,
        Pipes::Shard.new,
        Pipes::Git.new,
      ] + produce + [
        Pipes::Archive.new,
        Pipes::Nfpm.new,
        Pipes::Checksum.new,
        Pipes::Changelog.new,
        Pipes::Metadata.new,
        # Generated before the release is published: what cannot be generated
        # must fail while nothing is public yet. Pushed after: the URLs they
        # hold only answer once the release is there.
        Pipes::Homebrew.new,
        Pipes::Aqua.new,
        Pipes::Release.new,
        Pipes::HomebrewPush.new,
        Pipes::AquaPush.new,
      ] of Pipe)
    end

    getter pipes : Array(Pipe)

    def initialize(pipes : Array)
      @pipes = pipes.map(&.as(Pipe))
    end

    def run(ctx : Context) : Nil
      check_skip_names(ctx.options.skip)
      prepare_dist(ctx)
      @pipes.each { |pipe| run_pipe(pipe, ctx) }
    end

    private def run_pipe(pipe : Pipe, ctx : Context) : Nil
      skipped = ctx.options.skip.find { |name| name == pipe.name || name == pipe.group }
      if skipped
        ctx.logger.step("#{pipe.description} skipped: --skip=#{skipped}")
      elsif reason = pipe.skip?(ctx)
        ctx.logger.step("#{pipe.description} skipped: #{reason}")
      else
        ctx.logger.step(pipe.description)
        ctx.logger.nest { pipe.run(ctx) }
      end
    end

    # --clean removes dist/ whatever it holds: `dist: src` passes every static
    # check, being a directory inside the project. A directory with files git
    # tracks is not an output directory.
    private def check_untracked(ctx : Context) : Nil
      tracked = Git.new(ctx.dir).run("ls-files", "--", ctx.config.dist).lines.reject(&.empty?)
      return if tracked.empty?
      shown = tracked.first(3).join(", ") + (tracked.size > 3 ? ", ..." : "")
      raise ConfigError.new("dist: #{ctx.config.dist}/ holds files tracked by git (#{shown}): --clean would delete them")
    rescue GitError
      # Not a git repository: nothing is tracked.
    end

    private def check_skip_names(names : Array(String)) : Nil
      required = @pipes.reject(&.skippable?).map(&.name)
      names.find { |name| required.includes?(name) }.try { |name| raise UsageError.new("#{name} cannot be skipped") }
      known = @pipes.select(&.skippable?).flat_map { |pipe| [pipe.name, pipe.group].compact }.uniq!
      unknown = names.find { |name| !known.includes?(name) }
      raise UsageError.new("unknown pipe in --skip: #{unknown} (known: #{known.join(", ")})") if unknown
    end

    # dist/ must start empty, so that nothing from a previous run can be
    # archived, checksummed or uploaded by mistake.
    private def prepare_dist(ctx : Context) : Nil
      # Checked here too, and not only by the validate pipe: this runs first,
      # and --clean must never be able to remove the project.
      ctx.config.dist_error.try { |error| raise ConfigError.new(error) }
      dist = ctx.dist_path
      if ctx.options.merge?
        # The split builds are in dist/ already: that is the whole point.
        raise UsageError.new("--clean cannot be combined with --merge") if ctx.options.clean?
        return
      end
      if ctx.options.clean?
        check_untracked(ctx)
        FileUtils.rm_rf(dist)
        # rm_rf reports nothing it could not remove.
        if Dir.exists?(dist)
          raise Error.new("#{ctx.config.dist}/ could not be emptied: remove it by hand")
        end
      elsif Dir.exists?(dist) && !Dir.empty?(dist)
        raise Error.new("#{ctx.config.dist}/ is not empty: remove it or use --clean")
      end
      Dir.mkdir_p(dist)
    end
  end
end
