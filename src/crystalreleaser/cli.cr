require "option_parser"

require "./config"
require "./error"
require "./host"
require "./init"
require "./licenses"
require "./logger"
require "./pipeline"
require "./validator"
require "./version"

module Crystalreleaser
  # Command line front-end. It never calls `exit` and never touches the global
  # STDOUT/STDERR directly: both streams are injected and `#run` returns the
  # exit code, so specs drive it in-process. Only src/crystalreleaser.cr turns
  # that code into a process exit. `dir` is the project directory, injected
  # for the same reason: specs run several projects without `Dir.cd`.
  class CLI
    BANNER = "Usage: #{NAME} <command> [options]"

    # Subcommand => one-line description shown in the help.
    COMMANDS = {
      "init"      => "Generate a commented .crystalreleaser.yml from shard.yml",
      "check"     => "Load and validate the configuration",
      "build"     => "Build the binaries only",
      "release"   => "Build, package and publish a release",
      "changelog" => "Print the computed changelog on stdout",
      "licenses"  => "Print the third-party notices embedded in this binary",
    }

    def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR, @dir : String = Dir.current)
      @verbose = false
      @quiet = false
      @config_path = nil.as(String?)
      @command = nil.as(String?)
      @show_help = false
      @help = nil.as(String?)
      @show_version = false
      @options = Options.new
    end

    def run(args : Array(String)) : Int32
      parser = build_parser
      parser.parse(args.dup)
      raise UsageError.new("--verbose and --quiet are mutually exclusive") if @verbose && @quiet

      command = @command
      if @show_version
        @stdout.puts Crystalreleaser.version_line
      elsif @show_help || command.nil?
        # No command: the help is the only honest answer, and it goes to
        # stdout because the user asked for nothing wrong.
        @stdout.puts(@help || parser)
      else
        dispatch(command)
      end
      0
    rescue e : Error
      report(e)
      1
    rescue e : IO::Error
      # stdout closed by its reader (`crystalreleaser --help | head`): there
      # is nobody left to tell. Any other IO error is a bug and keeps its
      # backtrace.
      raise e unless @stdout.closed? || e.os_error == Errno::EPIPE
      1
    end

    private def build_parser : OptionParser
      OptionParser.new do |opts|
        opts.banner = BANNER

        COMMANDS.each do |name, description|
          opts.on(name, description) do
            @command = name
            opts.banner = "Usage: #{NAME} #{name} [options]"
            command_options(opts, name)
          end
        end

        opts.separator
        opts.separator "Global options:"
        opts.on("-f FILE", "--config=FILE", "Configuration file (default: .crystalreleaser.yml)") { |path| @config_path = path }
        opts.on("--verbose", "Verbose output, backtraces on error") { @verbose = true }
        opts.on("--quiet", "Only print warnings and errors") { @quiet = true }
        opts.on("--version", "Print the version and exit") { @show_version = true }
        # The text is taken here: the options of a command only exist in the
        # parser while it parses, they are gone once `parse` returns.
        opts.on("-h", "--help", "Print this help and exit") do
          @show_help = true
          @help = opts.to_s
        end

        opts.invalid_option { |flag| raise UsageError.new("unknown option: #{flag}") }
        opts.missing_option { |flag| raise UsageError.new("missing value for option: #{flag}") }
        opts.unknown_args do |args, after_dash|
          raise UsageError.new("unexpected argument: #{after_dash.first}") unless after_dash.empty?
          next if args.empty?
          first = args.first
          # With subcommands declared, OptionParser routes an unknown flag
          # given before any command here rather than to `invalid_option`.
          raise UsageError.new("unknown option: #{first}") if first.starts_with?('-')
          raise UsageError.new(@command ? "unexpected argument: #{first}" : "unknown command: #{first}")
        end
      end
    end

    # Options that only exist after their subcommand.
    private def command_options(opts : OptionParser, command : String) : Nil
      return unless command.in?("build", "release")
      opts.separator
      opts.separator "#{command.capitalize} options:"
      opts.on("--snapshot", "Build an untagged, possibly dirty tree as <next patch>-SNAPSHOT-<commit>") { @options.snapshot = true }
      opts.on("--clean", "Empty the dist directory first") { @options.clean = true }
      if command == "build"
        opts.on("--id=ID", "Only build this build id (repeatable)") { |id| @options.ids << id }
        opts.on("--split", "Build only what this host can (or --os/--arch), into dist/<os>_<arch>/") { @options.split = true }
        opts.on("--os=OS", "With --split: only this os") { |value| @options.split_os = value }
        opts.on("--arch=ARCH", "With --split: only this arch") { |arch| @options.split_arch = arch }
      else
        opts.on("--merge", "Release the binaries of split builds found in dist/ instead of building") { @options.merge = true }
        opts.on("--allow-missing", "With --merge: warn instead of failing when a platform is missing") { @options.allow_missing = true }
        opts.on("--skip=PIPES", "Comma-separated pipes to skip (e.g. publish,nfpm,before)") do |names|
          @options.skip.concat(names.split(',').map(&.strip).reject(&.empty?))
        end
        opts.on("--release-notes=FILE", "Use FILE as release notes instead of the changelog") { |file| @options.release_notes = file }
      end
      opts.on("--parallelism=N", "Number of builds run at once (default: CPU count)") do |value|
        count = value.to_i?
        raise UsageError.new("--parallelism expects a positive number, got '#{value}'") unless count && count > 0
        @options.parallelism = count
      end
    end

    private def dispatch(command : String) : Nil
      case command
      when "init"
        init
      when "check"
        check
      when "build"
        build
      when "release"
        release
      when "changelog"
        changelog
      when "licenses"
        print_licenses
      else
        raise UsageError.new("unknown command: #{command}")
      end
    end

    private def logger : Logger
      level =
        if @verbose
          Logger::Level::Debug
        elsif @quiet
          Logger::Level::Warn
        else
          Logger::Level::Info
        end
      Logger.new(@stderr, level)
    end

    private def load_config(log : Logger, host : Host) : Config
      config = Config.load(@dir, @config_path, host)
      if file = config.file
        log.step("loading configuration", file: file)
      else
        log.step("no configuration file, using defaults from shard.yml")
      end
      config
    rescue error : ConfigError
      # The step line still says which file was being read when it failed.
      log.step("loading configuration", file: @config_path || Config::FILE_NAMES.find { |name| File.file?(File.join(@dir, name)) } || "none")
      raise error
    end

    # Writes to -f when given, else .crystalreleaser.yml; refuses when any
    # config the lookup would find already exists.
    private def init : Nil
      path = @config_path || Config::FILE_NAMES.first
      if @config_path.nil? && (existing = Config::FILE_NAMES.find { |name| File.exists?(File.join(@dir, name)) })
        raise UsageError.new("#{existing} already exists")
      end
      Init.write(@dir, path)
      logger.step("wrote #{path}")
    end

    private def check : Nil
      log = logger
      host = Host.current
      config = load_config(log, host)
      warnings = Validator.new(config, host).run!
      log.nest { warnings.each { |warning| log.warn(warning) } }
      log.step("configuration is valid")
    end

    private def build : Nil
      if (@options.split_os || @options.split_arch) && !@options.split?
        raise UsageError.new("--os and --arch need --split")
      end
      log = logger
      host = Host.current
      config = load_config(log, host)
      ctx = Context.new(@dir, config, host, @options, log)
      Pipeline.build.run(ctx)
      log.step("build succeeded", dist: config.dist)
    end

    private def release : Nil
      log = logger
      host = Host.current
      config = load_config(log, host)
      @options.publish = true
      ctx = Context.new(@dir, config, host, @options, log)
      raise UsageError.new("--allow-missing needs --merge") if @options.allow_missing? && !@options.merge?
      # Checked now, not by the changelog pipe once everything is built.
      if (notes = @options.release_notes) && !File.file?(File.expand_path(notes, @dir))
        raise UsageError.new("release notes file not found: #{notes}")
      end
      Pipeline.release(@options.merge?).run(ctx)
      log.step("release succeeded", version: ctx.version_info.version, dist: config.dist)
    end

    # The changelog the next release would carry: since the previous tag when
    # HEAD is tagged, since the last tag otherwise. Prints on stdout, writes
    # nothing.
    private def changelog : Nil
      log = logger
      host = Host.current
      config = load_config(log, host)
      warnings = Validator.new(config, host).run!
      log.nest { warnings.each { |warning| log.warn(warning) } }
      ctx = Context.new(@dir, config, host, @options, log)
      git = Git.new(@dir)
      # Only an untagged HEAD falls back to the last tag: an error of
      # `previous_tag` (a shallow clone) is the one `release` stops on.
      tag =
        begin
          git.current_tag
        rescue GitError
          nil
        end
      ctx.previous_tag = tag ? git.previous_tag(tag) : git.last_tag
      @stdout.print Pipes::Changelog.compute(ctx)
    end

    private def print_licenses : Nil
      Licenses::FILES.each_with_index do |(name, text), index|
        @stdout.puts if index > 0
        @stdout.puts "==> #{name} <=="
        @stdout.print text
      end
    end

    private def report(error : Error) : Nil
      @stderr.puts "#{NAME}: #{error.message}"
      # --quiet wins over --verbose, so the conflict error itself stays terse.
      return if !@verbose || @quiet
      error.backtrace?.try &.each { |frame| @stderr.puts "  #{frame}" }
    end
  end
end
