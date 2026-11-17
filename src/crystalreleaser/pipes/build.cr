require "json"

require "../artifact"
require "../builders/builder"
require "../builders/cross"
require "../builders/docker"
require "../builders/native"
require "../context"
require "../pipe"
require "./checksum"

module Crystalreleaser
  module Pipes
    # Compiles every (build, platform) pair this host can produce, in
    # parallel, and registers the binaries. Pairs another host must build
    # (a native darwin build on Linux, windows) are skipped with a warning:
    # that is what lets the split mode spread a release over several runners.
    #
    # Emulated docker builds (arm64 on an amd64 host) run one at a time,
    # beside the parallel pool: several QEMU compilations at once only thrash.
    class Build < Pipe
      record Job, build : Config::Build, platform : Config::Platform, builder : Builders::Builder

      def name : String
        "build"
      end

      def description : String
        "building binaries"
      end

      def skippable? : Bool
        false
      end

      def run(ctx : Context) : Nil
        jobs = plan(ctx)
        raise BuildError.new("nothing to build for this host (#{ctx.host})") if jobs.empty?

        # Read once here: both are memoized on first use, which the parallel
        # jobs below would otherwise all trigger at the same time.
        ctx.crystal_version
        jobs.map(&.builder).uniq!.each(&.available?)

        errors = run_parallel(jobs, ctx)
        unless errors.empty?
          raise BuildError.new("build failed:\n" + errors.join('\n') { |error| "  - #{error}" })
        end
        write_split_metadata(ctx, jobs) if ctx.options.split?
      end

      private def builders(ctx : Context) : Hash(String, Builders::Builder)
        {
          "native" => Builders::Native.new(ctx.host).as(Builders::Builder),
          "docker" => Builders::Docker.new(ctx.host).as(Builders::Builder),
          "cross"  => Builders::Cross.new(ctx.host).as(Builders::Builder),
        }
      end

      private def plan(ctx : Context) : Array(Job)
        builders = builders(ctx)
        jobs = [] of Job
        selected_builds(ctx).each do |build|
          build.platforms.each do |platform|
            builder = builders[platform.strategy]
            job = Job.new(build, platform, builder)
            jobs << job if keep?(job, ctx)
          end
        end
        jobs
      end

      private def keep?(job : Job, ctx : Context) : Bool
        build, platform, builder = job.build, job.platform, job.builder
        couple = "#{platform.os}/#{platform.arch}"
        options = ctx.options
        return false if filtered_out?(platform, options)
        if platform.os == "windows"
          ctx.logger.warn("skipping #{build.id} #{couple}: windows builds are not supported yet")
          return false
        end
        if platform.strategy == "native" && !ctx.host.matches?(platform.os, platform.arch)
          ctx.logger.warn("skipping #{build.id} #{couple}: native build on a #{ctx.host} host")
          return false
        end
        # By default a split runner takes what it can build and leaves the
        # rest to the others; an explicit --os/--arch must be honoured.
        if options.split? && options.split_os.nil? && options.split_arch.nil? && !builder.compatible?(build, platform, ctx)
          ctx.logger.info("leaving #{build.id} #{couple} (#{platform.strategy}) to another runner")
          return false
        end
        true
      end

      # Outside the --os/--arch of a split build.
      private def filtered_out?(platform : Config::Platform, options : Options) : Bool
        return false unless options.split?
        os, arch = options.split_os, options.split_arch
        (!os.nil? && os != platform.os) || (!arch.nil? && arch != platform.arch)
      end

      private def selected_builds(ctx : Context) : Array(Config::Build)
        ids = ctx.options.ids
        builds = ctx.config.builds
        return builds if ids.empty?
        unknown = ids.reject { |id| builds.any? { |build| build.id == id } }
        raise UsageError.new("unknown build id in --id: #{unknown.join(", ")}") unless unknown.empty?
        builds.select { |build| ids.includes?(build.id) }
      end

      # Returns the error messages of the jobs that failed: every job runs,
      # so one broken platform does not hide the state of the others.
      private def run_parallel(jobs : Array(Job), ctx : Context) : Array(String)
        serial, parallel = jobs.partition { |job| job.builder.serial?(job.platform, ctx) }
        results = Channel(String?).new(jobs.size)
        start_workers(parallel, ctx.options.parallelism, results, ctx)
        start_workers(serial, 1, results, ctx)
        Array.new(jobs.size) { results.receive }.compact
      end

      private def start_workers(jobs : Array(Job), count : Int32, results : Channel(String?), ctx : Context) : Nil
        return if jobs.empty?
        queue = Channel(Job).new(jobs.size)
        jobs.each { |job| queue.send(job) }
        queue.close
        Math.min(count, jobs.size).times do
          spawn do
            while job = queue.receive?
              results.send(run_job(job, ctx))
            end
          end
        end
      end

      private def run_job(job : Job, ctx : Context) : String?
        build, platform = job.build, job.platform
        ctx.logger.info(build.id, os: platform.os, arch: platform.arch, strategy: platform.strategy)
        path = job.builder.build(build, platform, ctx)
        register(ctx, build, platform, path)
        nil
      rescue error : Error
        error.message
      rescue error : Exception
        "#{job.build.id} #{job.platform.os}/#{job.platform.arch}: #{error.class}: #{error.message}"
      end

      private def register(ctx : Context, build : Config::Build, platform : Config::Platform, path : Path) : Nil
        if platform.os == "darwin"
          Builders.check_darwin_libraries(path.to_s, "#{build.id} #{platform.os}/#{platform.arch}").try do |warning|
            ctx.logger.warn(warning)
          end
        end
        triple = Builders.triple(platform.os, platform.arch, platform.static?)
        ctx.artifacts.add(Artifact.new(Artifact::Type::Binary, build.binary, ctx.relative(path.to_s),
          os: platform.os, arch: platform.arch, build_id: build.id, size: File.size(path),
          extra: {"target" => triple, "static" => platform.static?.to_s}))
        if description = Builders.describe(path.to_s)
          Builders.file_warnings(description, platform.os, platform.arch, static: platform.static?).each do |warning|
            ctx.logger.warn("#{build.id} #{platform.os}/#{platform.arch}: #{warning}")
          end
        end
      end

      # dist/<os>_<arch>/artifacts.json and metadata.json: what `release
      # --merge` reads back on the final runner.
      private def write_split_metadata(ctx : Context, jobs : Array(Job)) : Nil
        jobs.map { |job| {job.platform.os, job.platform.arch} }.uniq!.each do |(os, arch)|
          dir = ctx.dist_path("#{os}_#{arch}")
          binaries = ctx.artifacts.filter(type: Artifact::Type::Binary, os: os, arch: arch)
          # What the merge checks each binary against once it has travelled.
          binaries.each { |binary| binary.sha256 ||= Checksum.sha256(File.join(ctx.dir, binary.path)) }
          File.write(File.join(dir, "artifacts.json"), binaries.to_pretty_json + "\n")
          File.write(File.join(dir, "metadata.json"), {
            version: ctx.version_info.version,
            tag:     ctx.version_info.tag,
            commit:  ctx.commit,
            os:      os,
            arch:    arch,
          }.to_pretty_json + "\n")
          ctx.logger.info("#{ctx.config.dist}/#{os}_#{arch}/artifacts.json")
        end
      end
    end
  end
end
