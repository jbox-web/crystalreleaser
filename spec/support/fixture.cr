require "file_utils"

# A throw-away Crystal project in its own temporary directory, with a git
# repository driven from the spec. Every git call runs with the user's global
# and system configuration switched off, so that a signing or hook setting on
# the developer's machine cannot change what the fixture produces, and with a
# fixed identity and a monotonic fake clock so commits are reproducible.
module Fixture
  DEFAULT_SHARD = <<-YAML
    name: toy
    version: 0.1.0
    targets:
      toy:
        main: src/toy.cr
    YAML

  TOY_SOURCE = <<-CR
    puts "toy"
    CR

  class Project
    getter dir : String

    # Seconds since the epoch of the next commit; bumped by each commit.
    @clock = 1_700_000_000_i64

    def initialize(@dir : String)
    end

    def path(relative : String) : String
      File.join(@dir, relative)
    end

    def write(relative : String, content : String) : Nil
      full = path(relative)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def git(*args : String) : String
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("git", args.to_a, chdir: @dir, env: git_env, output: output, error: error)
      raise "git #{args.join(' ')} failed: #{error}" unless status.success?
      output.to_s.chomp
    end

    def init_git : Nil
      git("init", "-q", "-b", "master")
    end

    # Commits every pending change, after touching `file` so there is
    # always something to commit.
    def commit(message : String, file : String = "CHANGES") : String
      write(file, "#{message}\n")
      git("add", "--all")
      @clock += 60
      git("commit", "-q", "-m", message)
      git("rev-parse", "HEAD")
    end

    def tag(name : String) : Nil
      git("tag", name)
    end

    def commit_time : Int64
      @clock
    end

    private def git_env : Hash(String, String)
      date = "#{@clock} +0000"
      {
        "GIT_CONFIG_GLOBAL"   => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_AUTHOR_NAME"     => "Spec",
        "GIT_AUTHOR_EMAIL"    => "spec@example.com",
        "GIT_COMMITTER_NAME"  => "Spec",
        "GIT_COMMITTER_EMAIL" => "spec@example.com",
        "GIT_AUTHOR_DATE"     => date,
        "GIT_COMMITTER_DATE"  => date,
      }
    end
  end

  # Yields a project holding `shard` as shard.yml, plus `config` as
  # .crystalreleaser.yml when given. The directory is removed afterwards.
  def self.project(shard : String = DEFAULT_SHARD, config : String? = nil, & : Project ->) : Nil
    dir = File.join(Dir.tempdir, "crystalreleaser-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      project = Project.new(dir)
      project.write("shard.yml", shard)
      project.write("src/toy.cr", TOY_SOURCE)
      project.write(".crystalreleaser.yml", config) if config
      yield project
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
