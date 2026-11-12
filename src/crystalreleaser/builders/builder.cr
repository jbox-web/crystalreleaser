require "../config"
require "../error"
require "../subprocess"

module Crystalreleaser
  class Context
  end

  # The three ways of producing a binary: native, docker, cross.
  module Builders
    # LLVM target triples. Linux is musl when static (the only libc Crystal
    # links statically), glibc otherwise.
    def self.triple(os : String, arch : String, static : Bool) : String
      case {os, arch}
      when {"linux", "amd64"}   then static ? "x86_64-linux-musl" : "x86_64-linux-gnu"
      when {"linux", "arm64"}   then static ? "aarch64-linux-musl" : "aarch64-linux-gnu"
      when {"darwin", "amd64"}  then "x86_64-apple-darwin"
      when {"darwin", "arm64"}  then "aarch64-apple-darwin"
      when {"freebsd", "amd64"} then "x86_64-portbld-freebsd"
      else                           raise BuildError.new("no target triple for #{os}/#{arch}")
      end
    end

    # The words `file` uses for each architecture: ELF says x86-64/aarch64,
    # Mach-O says x86_64/arm64.
    ARCH_MARKERS = {
      "amd64" => {"x86-64", "x86_64"},
      "arm64" => {"aarch64", "arm64"},
    }

    # Checks the description `file -b` gives of a binary against what was
    # asked. Returns warnings: a surprising `file` output is worth reporting,
    # not worth failing a release over.
    def self.file_warnings(description : String, os : String, arch : String, *, static : Bool) : Array(String)
      warnings = [] of String
      markers = ARCH_MARKERS[arch]?
      if markers && markers.none? { |marker| description.includes?(marker) }
        warnings << "expected an #{arch} binary, `file` reports: #{description}"
      end
      if static && !description.includes?("statically linked") && !description.includes?("static-pie linked")
        warnings << "expected a statically linked binary, `file` reports: #{description}"
      end
      warnings
    end

    # Runs `file -b` on a binary when `file` is installed.
    def self.describe(path : String) : String?
      return unless Process.find_executable("file")
      output = IO::Memory.new
      status = Process.run("file", ["-b", path], output: output, error: Process::Redirect::Close)
      status.success? ? output.to_s.strip : nil
    end

    # Where a build lands: dist/<id>_<os>_<arch>/<binary>, or under
    # dist/<os>_<arch>/ in split mode so each runner's share can be uploaded
    # and merged as one folder.
    def self.output_path(ctx : Context, build : Config::Build, platform : Config::Platform) : String
      leaf = "#{build.id}_#{platform.os}_#{platform.arch}"
      if ctx.options.split?
        ctx.dist_path("#{platform.os}_#{platform.arch}", leaf, build.binary)
      else
        ctx.dist_path(leaf, build.binary)
      end
    end

    # Runs a command, returns {success, stdout + stderr}.
    def self.capture(args : Array(String), *, chdir : String? = nil, env : Hash(String, String)? = nil,
                     clear_env : Bool = false) : {Bool, String}
      status, output = Subprocess.run(args[0], args[1..], chdir: chdir, env: env, clear_env: clear_env)
      {status.success?, output}
    rescue File::NotFoundError
      {false, "#{args[0]}: command not found"}
    end

    abstract class Builder
      abstract def available? : Bool

      # Whether this host can build `platform` with this builder at all.
      def compatible?(build : Config::Build, platform : Config::Platform, ctx : Context) : Bool
        available?
      end

      # Builds that must not run in parallel with each other (emulation).
      def serial?(platform : Config::Platform, ctx : Context) : Bool
        false
      end

      def label(build : Config::Build, platform : Config::Platform) : String
        "#{build.id} #{platform.os}/#{platform.arch}"
      end

      # Builds `build` for `platform`, returns the path of the binary.
      abstract def build(build : Config::Build, platform : Config::Platform, ctx : Context) : Path
    end
  end
end
