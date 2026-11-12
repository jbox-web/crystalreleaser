module Crystalreleaser
  class Context
  end

  # One stage of the release. `name` is what --skip accepts; `group`, when
  # set, is a second name covering several pipes (`publish`).
  abstract class Pipe
    abstract def name : String

    # The line logged when the pipe starts.
    abstract def description : String

    def group : String?
      nil
    end

    # Whether --skip may name this pipe. False for the ones a run means
    # nothing without: the validation, the git state, the binaries.
    def skippable? : Bool
      true
    end

    # The reason to skip this run, or nil to run it.
    def skip?(ctx : Context) : String?
      nil
    end

    abstract def run(ctx : Context) : Nil

    # Writes an output file through a temporary neighbour, renamed once the
    # block is done: a writer that fails halfway leaves nothing in dist/,
    # where a truncated file would make the next run stop on "dist/ is not
    # empty".
    protected def write_output(path : String, & : File ->) : Nil
      partial = "#{path}.tmp"
      begin
        File.open(partial, "w") { |file| yield file }
      rescue error
        File.delete?(partial)
        raise error
      end
      File.rename(partial, path)
    end
  end
end
