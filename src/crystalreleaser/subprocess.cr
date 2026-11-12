module Crystalreleaser
  # Runs child processes whose stdout and stderr are read back as one text.
  module Subprocess
    # Runs `command` and returns its status with stdout and stderr merged, in
    # the order the child wrote them.
    #
    # The child gets one pipe as both streams and this fiber is its only
    # reader. Handing one IO::Memory to `Process.run` as `output:` and `error:`
    # instead makes the stdlib copy each stream from its own fiber: under
    # -Dpreview_mt, two threads then write the same unsynchronized buffer,
    # which loses bytes, spins forever or aborts in the GC.
    #
    # Raises File::NotFoundError when the command or `chdir` does not exist.
    def self.run(command : String, args : Array(String), *, chdir : String? = nil,
                 env : Hash(String, String)? = nil, clear_env : Bool = false) : {Process::Status, String}
      run(command, args, chdir: chdir, env: env, clear_env: clear_env) { }
    end

    # Same, and yields each line, without its newline, as soon as the child
    # has written it: a caller can show the output of a command that hangs.
    def self.run(command : String, args : Array(String), *, chdir : String? = nil,
                 env : Hash(String, String)? = nil, clear_env : Bool = false, & : String ->) : {Process::Status, String}
      reader, writer = IO.pipe
      begin
        process = Process.new(command, args, chdir: chdir, env: env, clear_env: clear_env,
          input: Process::Redirect::Close, output: writer, error: writer)
      ensure
        # The child holds its own copy: with ours open, the pipe never ends.
        writer.close
      end
      text = String.build do |io|
        reader.each_line(chomp: false) do |line|
          io << line
          yield line.chomp
        end
      end
      {process.wait, text}
    ensure
      reader.try(&.close)
    end

    # How a failed process ended, for an error message: `exit 3`, or
    # `killed by signal KILL`. `Process::Status#exit_code` raises on the
    # latter.
    def self.describe(status : Process::Status) : String
      if code = status.exit_code?
        "exit #{code}"
      elsif signal = status.exit_signal?
        "killed by signal #{signal}"
      else
        "abnormal termination"
      end
    end
  end
end
