require "file_utils"

require "./error"
require "./subprocess"

module Crystalreleaser
  # OpenPGP signatures made by the gpg of the machine, with a private key
  # given as text (what `gpg --armor --export-secret-keys` prints).
  #
  # The key and its passphrase are secrets, and are handled as such:
  #
  # - they reach gpg in files, never as arguments, which every process of the
  #   machine can read (`ps`), and never through this program's output;
  # - these files live in a directory of their own, created 0700, that is
  #   gpg's whole home for the run: the keyring of the user is neither read
  #   nor written;
  # - the directory is removed when the block ends, however it ends, after
  #   the daemons gpg started for it have been told to quit.
  #
  # An interrupted run (SIGINT, SIGTERM) removes it too. Only a process
  # killed outright (SIGKILL) leaves the directory behind: nothing can run
  # then.
  class Gpg
    # gpg is missing, or refused what it was asked.
    class Error < PackageError
    end

    # The longest path of a unix socket is 104 bytes on macOS and 108 on
    # Linux, and gpg puts the sockets of its daemons in its home when the
    # system has no /run/user: `S.gpg-agent.browser` is the longest name.
    SOCKET_PATH_LIMIT = 104 - "/S.gpg-agent.browser".bytesize

    # gpg's home for this run.
    getter home : String

    # Imports `key`, yields the signer, then removes every trace of the key.
    def self.open(key : String, passphrase : String = "", *, command : String = "gpg", & : Gpg -> T) : T forall T
      gpg = new(command)
      # An interrupted run (Ctrl-C, a cancelled or timed out CI job) ends
      # the process without running any `ensure`: the key and its passphrase
      # would stay on disk, and gpg's agent alive.
      Process.on_terminate do
        gpg.close
        exit 130
      end
      begin
        gpg.import(key, passphrase)
        yield gpg
      ensure
        Process.restore_interrupts!
        gpg.close
      end
    end

    protected def initialize(@command : String)
      @home = File.join(Dir.tempdir, "crel-gpg-#{Random::Secure.hex(6)}")
      @passphrase_file = File.join(@home, "passphrase")
      @protected = false
      @created = 0_i64
      Dir.mkdir(@home, 0o700)
    end

    protected def import(key : String, passphrase : String) : Nil
      unless passphrase.empty?
        File.write(@passphrase_file, passphrase, perm: 0o600)
        @protected = true
      end
      key_file = File.join(@home, "key.asc")
      File.write(key_file, key, perm: 0o600)
      begin
        run(unlock + ["--import", key_file], "gpg could not import the signing key")
      ensure
        # gpg keeps the key in its own store from here on.
        File.delete?(key_file)
      end
      # One line per key: `sec` for a primary key, `ssb` for a subkey, with
      # its creation time (seconds since the epoch) as sixth field.
      keys = run(["--with-colons", "--list-secret-keys"], "gpg could not list the signing key")
        .lines.map(&.split(':')).select(&.[0].in?("sec", "ssb"))
      primary = keys.count { |fields| fields[0] == "sec" }
      if primary == 0
        raise Error.new("the signing key holds no private key: " \
                        "export it with gpg --armor --export-secret-keys <key id>")
      elsif primary > 1
        # gpg would pick the one that signs, and every public key would be
        # published.
        raise Error.new("the signing key holds #{primary} private keys: " \
                        "export the one that signs, with gpg --armor --export-secret-keys <key id>")
      end
      @created = keys.max_of { |fields| fields[5]?.try(&.to_i64?) || 0_i64 }
    end

    # A detached, binary signature of `data` (SHA256), as one OpenPGP packet.
    #
    # With `time`, the signature is dated then instead of now: the same data
    # signed again gives the same bytes, RSA and EdDSA signatures being
    # deterministic. Never before the key was created, though: gpg refuses
    # to sign then, and no verifier accepts a signature older than its key.
    def sign(data : Bytes, time : Time? = nil) : Bytes
      input = File.join(@home, "data")
      output = "#{input}.sig"
      File.write(input, data, perm: 0o600)
      # The `!` freezes the clock, which otherwise runs on from that time.
      clock = time ? ["--faked-system-time", "#{Math.max(time.to_unix, @created)}!"] : [] of String
      begin
        run(unlock + clock + ["--no-armor", "--digest-algo", "SHA256", "--output", output, "--detach-sign", input],
          "gpg could not sign")
        File.open(output, &.getb_to_end)
      ensure
        File.delete?(input)
        File.delete?(output)
      end
    end

    # The public half of the key, armored: what `rpm --import` reads.
    def public_key : String
      output = File.join(@home, "public.asc")
      begin
        run(["--armor", "--output", output, "--export"], "gpg could not export the public key")
        File.read(output)
      ensure
        File.delete?(output)
      end
    end

    protected def close : Nil
      # gpg starts an agent (and, since 2.4, a keybox daemon) bound to this
      # home: left alone, they would outlive the directory.
      Process.run("gpgconf", ["--homedir", @home, "--kill", "all"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    rescue IO::Error | RuntimeError
      # No gpgconf, hence no gpg either: nothing was started. And whatever
      # else fails here must not hide the error this cleanup follows.
    ensure
      FileUtils.rm_rf(@home)
    end

    # How gpg gets the passphrase without a terminal nor a pinentry window.
    private def unlock : Array(String)
      return ["--pinentry-mode", "loopback"] unless @protected
      ["--pinentry-mode", "loopback", "--passphrase-file", @passphrase_file]
    end

    private def run(args : Array(String), failure : String) : String
      status, output = Subprocess.run(@command, ["--homedir", @home, "--batch", "--no-tty"] + args)
      return output if status.success?
      hint = @home.bytesize > SOCKET_PATH_LIMIT ? "\nthe temporary directory may be too long for gpg's sockets: set TMPDIR to a shorter path" : ""
      raise Error.new("#{failure} (#{Subprocess.describe(status)}):\n#{output.strip}#{hint}")
    rescue File::NotFoundError
      raise Error.new("gpg is required to sign packages, and #{@command} was not found")
    end
  end
end
