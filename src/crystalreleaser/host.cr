module Crystalreleaser
  # The machine crystalreleaser runs on, in the os/arch vocabulary of the
  # config. Injected wherever a decision depends on it (native builds, static
  # linking) so specs can pretend to be another host.
  struct Host
    getter os : String
    getter arch : String
    # True when the compiler of this host links musl (Alpine), the only
    # Linux host where a native `--static` build works.
    getter? musl : Bool

    def initialize(@os : String, @arch : String, *, @musl : Bool)
    end

    def self.current : Host
      new(current_os, current_arch, musl: current_os == "linux" && musl_toolchain?)
    end

    # Whether `crystal build` links musl on this machine, read from the
    # default target the compiler prints (`x86_64-alpine-linux-musl`).
    #
    # Not `flag?(:musl)`: that is the libc crystalreleaser itself was
    # compiled against. The released Linux binary is a static musl one and
    # runs on glibc hosts, where it would then let a static native build
    # through; a glibc build would refuse one on Alpine.
    def self.musl_toolchain?(version_output : String = compiler_version) : Bool
      version_output.each_line.any? do |line|
        line.starts_with?("Default target:") && line.rstrip.ends_with?("musl")
      end
    end

    # `crystal --version`, or nothing when there is no compiler.
    private def self.compiler_version : String
      output = IO::Memory.new
      status = Process.run("crystal", ["--version"], output: output, error: Process::Redirect::Close)
      status.success? ? output.to_s : ""
    rescue File::NotFoundError
      ""
    end

    # The os this binary was compiled for, in the config vocabulary.
    def self.current_os : String
      {% if flag?(:linux) %}
        "linux"
      {% elsif flag?(:darwin) %}
        "darwin"
      {% elsif flag?(:freebsd) %}
        "freebsd"
      {% elsif flag?(:windows) %}
        "windows"
      {% else %}
        "unknown"
      {% end %}
    end

    # The architecture this binary was compiled for, in the config
    # vocabulary.
    def self.current_arch : String
      {% if flag?(:x86_64) %}
        "amd64"
      {% elsif flag?(:aarch64) %}
        "arm64"
      {% else %}
        "unknown"
      {% end %}
    end

    def matches?(os : String, arch : String) : Bool
      @os == os && @arch == arch
    end

    def to_s(io : IO) : Nil
      io << @os << '/' << @arch
    end
  end
end
