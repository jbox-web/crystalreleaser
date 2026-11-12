require "../context"
require "./builder"

module Crystalreleaser
  module Builders
    # Cross-compilation without docker: crystal emits an object file for the
    # target and prints the link command it would run; that command's
    # libraries are linked again with `zig cc` (or `cc`) against a sysroot
    # holding the target's static libraries (libgc, pcre2, libevent...).
    # crystalreleaser does not provide the sysroot; it checks it exists.
    class Cross < Builder
      ZIG_TRIPLES = {
        "x86_64-linux-musl"      => "x86_64-linux-musl",
        "aarch64-linux-musl"     => "aarch64-linux-musl",
        "x86_64-linux-gnu"       => "x86_64-linux-gnu",
        "aarch64-linux-gnu"      => "aarch64-linux-gnu",
        "x86_64-apple-darwin"    => "x86_64-macos",
        "aarch64-apple-darwin"   => "aarch64-macos",
        "x86_64-portbld-freebsd" => "x86_64-freebsd",
      }

      def initialize(@host : Host)
      end

      def available? : Bool
        !Process.find_executable("crystal").nil?
      end

      def compatible?(build : Config::Build, platform : Config::Platform, ctx : Context) : Bool
        available? && linker_available?(build) && Dir.exists?(sysroot(build, platform, ctx))
      rescue BuildError
        false
      end

      def linker_available?(build : Config::Build) : Bool
        !Process.find_executable(build.cross.linker == "zig" ? "zig" : "cc").nil?
      end

      def sysroot(build : Config::Build, platform : Config::Platform, ctx : Context) : String
        index = ctx.config.builds.index(build) || 0
        source = build.cross.sysroot || raise BuildError.new("#{label(build, platform)}: cross.sysroot is not set")
        ctx.render(source, "builds[#{index}].cross.sysroot", ctx.platform_vars(build, platform))
      end

      def compile_command(build : Config::Build, platform : Config::Platform, ctx : Context) : Array(String)
        main = build.main || raise BuildError.new("#{label(build, platform)}: no main file")
        triple = Builders.triple(platform.os, platform.arch, platform.static?)
        args = ["crystal", "build", main, "--cross-compile", "--target", triple,
                "-o", Builders.output_path(ctx, build, platform)]
        args.concat(build.flags)
        args << "--static" if platform.static?
        args
      end

      # A library crystal looks up with pkg-config, as it prints it in the
      # link command: a shell command substitution, whose fallback names the
      # libraries.
      PKG_CONFIG_LOOKUP = /`[^`]*\|\|\s*printf %s '([^']*)'\s*`/

      # The -l and -L flags of the link command crystal prints.
      #
      # The command is a shell line, and the libraries found through
      # pkg-config are command substitutions in it: each is replaced by its
      # fallback (`-lssl -lcrypto`), which is what a build for another machine
      # wants anyway, since pkg-config would answer for this one. Splitting
      # the line as it is would hand the linker pieces of those commands.
      def self.link_flags(output : String) : Array(String)
        line = output.lines.reverse!.find { |candidate| candidate.includes?(".o") && candidate.includes?(" -o ") }
        unless line
          raise BuildError.new("no link command in the output of crystal build --cross-compile:\n#{output.strip}")
        end
        line = line.gsub(PKG_CONFIG_LOOKUP) { $1 }
        if unread = line.match(/`[^`]*`?/)
          raise BuildError.new("cannot read the libraries of #{unread[0]} in the link command")
        end
        Process.parse_arguments_posix(line.strip).select { |arg| arg.starts_with?("-l") || arg.starts_with?("-L") }.uniq!
      end

      # `cc --version`, which tells clang from gcc.
      def self.cc_version : String
        Builders.capture(["cc", "--version"])[1]
      end

      # Host library paths are dropped: they point to the build machine. The
      # sysroot's own library folders replace them.
      def link_command(build : Config::Build, platform : Config::Platform, ctx : Context, flags : Array(String),
                       cc_version : String? = nil) : Array(String)
        triple = Builders.triple(platform.os, platform.arch, platform.static?)
        root = sysroot(build, platform, ctx)
        output = Builders.output_path(ctx, build, platform)
        # zig prefixes even absolute -L paths with --sysroot, and brings its
        # own libc for the target: it only gets the sysroot's library folders.
        # gcc and clang take --sysroot for the libc and headers. clang links
        # for any target with --target; gcc has no such option and only links
        # for the target it was built for, so the cross gcc of the target is
        # called, under the name it is installed with (<triple>-gcc).
        args =
          if build.cross.linker == "zig"
            ["zig", "cc", "-target", ZIG_TRIPLES[triple]]
          elsif (cc_version || Cross.cc_version).includes?("clang")
            ["cc", "--target=#{triple}", "--sysroot", root]
          else
            ["#{triple}-gcc", "--sysroot", root]
          end
        args.concat(["#{output}.o", "-o", output])
        args << "-static" if platform.static?
        {"lib", "usr/lib", "usr/local/lib"}.each { |dir| args << "-L#{File.join(root, dir)}" }
        args.concat(flags.select(&.starts_with?("-l")))
        # gcc links libgcc_eh implicitly; zig cc does not, and Crystal's
        # exception handling needs its _Unwind_* symbols. zig builds its own
        # libunwind for the target.
        args << "-lunwind" if build.cross.linker == "zig" && platform.os == "linux"
        args.concat(build.cross.link_flags)
      end

      def build(build : Config::Build, platform : Config::Platform, ctx : Context) : Path
        root = sysroot(build, platform, ctx)
        unless Dir.exists?(root)
          raise BuildError.new("#{label(build, platform)}: sysroot not found: #{root} (it must hold the target's " \
                               "static libraries; crystalreleaser does not provide it)")
        end
        unless linker_available?(build)
          raise BuildError.new("#{label(build, platform)}: linker #{build.cross.linker} is not installed")
        end
        output = Builders.output_path(ctx, build, platform)
        Dir.mkdir_p(File.dirname(output))
        env = ctx.build_env(build, platform)

        compile = compile_command(build, platform, ctx)
        ctx.logger.debug(compile.join(' '))
        ok, log = Builders.capture(compile, chdir: ctx.dir, env: env, clear_env: true)
        raise BuildError.new("#{label(build, platform)}: #{log.strip}") unless ok

        flags =
          begin
            Cross.link_flags(log)
          rescue error : BuildError
            raise BuildError.new("#{label(build, platform)}: #{error.message}")
          end
        link = link_command(build, platform, ctx, flags)
        unless Process.find_executable(link[0])
          raise BuildError.new("#{label(build, platform)}: linker #{link[0]} is not installed (cc is gcc here, which " \
                               "only links for its own target: install that cross gcc or clang, or use cross.linker: zig)")
        end
        ctx.logger.debug(link.join(' '))
        ok, link_log = Builders.capture(link, chdir: ctx.dir, env: env, clear_env: true)
        raise BuildError.new("#{label(build, platform)}: link failed: #{link_log.strip}") unless ok
        File.delete?("#{output}.o")
        Path[output]
      end
    end
  end
end
