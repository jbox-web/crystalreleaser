require "../context"
require "./builder"

module Crystalreleaser
  module Builders
    # `crystal build` on the host itself. Only builds for the host platform;
    # static only on a musl host, since glibc cannot be linked statically.
    class Native < Builder
      def initialize(@host : Host)
      end

      def available? : Bool
        !Process.find_executable("crystal").nil?
      end

      def compatible?(build : Config::Build, platform : Config::Platform, ctx : Context) : Bool
        available? && @host.matches?(platform.os, platform.arch)
      end

      def command(build : Config::Build, platform : Config::Platform, ctx : Context) : Array(String)
        main = build.main || raise BuildError.new("#{label(build, platform)}: no main file")
        args = ["crystal", "build", main, "-o", Builders.output_path(ctx, build, platform)]
        args.concat(build.flags)
        if platform.static?
          unless @host.os == "linux" && @host.musl?
            raise BuildError.new("#{label(build, platform)}: static linking needs a musl host (e.g. Alpine), " \
                                 "this one uses glibc; use strategy: docker")
          end
          args << "--static"
        end
        args
      end

      def build(build : Config::Build, platform : Config::Platform, ctx : Context) : Path
        args = command(build, platform, ctx)
        output = Builders.output_path(ctx, build, platform)
        Dir.mkdir_p(File.dirname(output))
        ctx.logger.debug(args.join(' '))

        status, log = Subprocess.run(args[0], args[1..], chdir: ctx.dir, env: ctx.build_env(build, platform),
          clear_env: true)
        raise BuildError.new("#{label(build, platform)}: #{log.strip}") unless status.success?
        Path[output]
      end
    end
  end
end
