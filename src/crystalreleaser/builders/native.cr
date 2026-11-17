require "file_utils"

require "../context"
require "./builder"

module Crystalreleaser
  module Builders
    # `crystal build` on the host itself. Only builds for the host platform;
    # static only on a musl host, since glibc cannot be linked statically.
    #
    # On darwin, `static_libs` links the listed libraries of a Homebrew
    # formula statically: their `.a` files are copied into a folder of their
    # own, outside the project, passed first to the linker by an absolute
    # `-L` (the linker runs in the compiler's cache). ld64 has no "static for
    # this library only" switch: it takes the first folder of its search path
    # that holds the library, and that folder holds nothing but the `.a`.
    class Native < Builder
      # Where Homebrew keeps a formula, or nil when it is not installed.
      alias BrewPrefix = Proc(String, String?)

      def initialize(@host : Host, @brew_prefix : BrewPrefix = ->(formula : String) { Native.brew_prefix(formula) })
      end

      # `brew --prefix <formula>`, which answers even for a formula that is
      # not installed: the folder must exist as well.
      def self.brew_prefix(formula : String) : String?
        output = IO::Memory.new
        status = Process.run("brew", ["--prefix", formula], output: output, error: Process::Redirect::Close)
        prefix = output.to_s.strip
        status.success? && !prefix.empty? && Dir.exists?(prefix) ? prefix : nil
      rescue File::NotFoundError
        nil
      end

      def available? : Bool
        !Process.find_executable("crystal").nil?
      end

      def compatible?(build : Config::Build, platform : Config::Platform, ctx : Context) : Bool
        available? && @host.matches?(platform.os, platform.arch)
      end

      # The folder of the static libraries of a darwin build, filled, or nil
      # when there are none to link. The caller removes it.
      def static_libs_dir(build : Config::Build, platform : Config::Platform, ctx : Context) : String?
        static = build.static_libs
        return unless static && platform.os == "darwin"
        formula = static.formula
        prefix = @brew_prefix.call(formula) ||
                 raise BuildError.new("#{label(build, platform)}: static_libs: Homebrew has no #{formula} installed; " \
                                      "install it with `brew install #{formula}`")
        archives = static.libs.map do |name|
          archive = File.join(prefix, "lib", "lib#{name}.a")
          unless File.file?(archive)
            raise BuildError.new("#{label(build, platform)}: static_libs: #{formula} has no lib#{name}.a in #{prefix}/lib")
          end
          archive
        end
        dir = File.join(Dir.tempdir, "crystalreleaser-static-#{build.id.gsub(/[^a-zA-Z0-9_.-]/, '_')}-#{Random::Secure.hex(6)}")
        Dir.mkdir_p(dir)
        archives.each { |archive| FileUtils.cp(archive, File.join(dir, File.basename(archive))) }
        File.realpath(dir)
      end

      def command(build : Config::Build, platform : Config::Platform, ctx : Context,
                  static_dir : String? = nil) : Array(String)
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
        args.concat(["--link-flags", "-L#{static_dir}"]) if static_dir
        args
      end

      # The environment of the compiler. With static_libs on darwin, the
      # formula's pkg-config folder comes first: Crystal declares the OpenSSL
      # API of the version `pkg-config --modversion` reports (lib_ssl.cr), and
      # that must be the formula whose archives are linked, not whichever one
      # Homebrew has linked (openssl@3 next to openssl@4 on macos-26-intel).
      def environment(build : Config::Build, platform : Config::Platform, ctx : Context) : Hash(String, String)
        env = ctx.build_env(build, platform)
        static = build.static_libs
        return env unless static && platform.os == "darwin"
        prefix = @brew_prefix.call(static.formula)
        return env unless prefix
        folder = File.join(prefix, "lib", "pkgconfig")
        env["PKG_CONFIG_PATH"] = env["PKG_CONFIG_PATH"]?.presence.try { |rest| "#{folder}:#{rest}" } || folder
        env
      end

      def build(build : Config::Build, platform : Config::Platform, ctx : Context) : Path
        static_dir = static_libs_dir(build, platform, ctx)
        args = command(build, platform, ctx, static_dir)
        output = Builders.output_path(ctx, build, platform)
        Dir.mkdir_p(File.dirname(output))
        ctx.logger.debug(args.join(' '))

        status, log = Subprocess.run(args[0], args[1..], chdir: ctx.dir, env: environment(build, platform, ctx),
          clear_env: true)
        raise BuildError.new("#{label(build, platform)}: #{log.strip}") unless status.success?
        Path[output]
      ensure
        static_dir.try { |dir| FileUtils.rm_rf(dir) }
      end
    end
  end
end
