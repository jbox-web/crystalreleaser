require "colorize"

module Crystalreleaser
  # Human-oriented progress log: one line per step, nested lines indented by
  # two spaces, optional `key=value` fields, colour only when asked (by
  # default: when the stream is a terminal). Logs go to stderr; stdout is kept
  # for command output such as `changelog`.
  class Logger
    enum Level
      Debug
      Info
      Warn
      Error
    end

    getter level : Level

    def initialize(@io : IO, @level : Level = Level::Info, color : Bool? = nil)
      @color = color.nil? ? @io.tty? : color
      @depth = 0
      # Builds log from parallel fibers, possibly on several threads.
      @mutex = Mutex.new
    end

    def step(message : String, **fields) : Nil
      write(Level::Info, "• ", message, fields, :default, @depth)
    end

    def info(message : String, **fields) : Nil
      write(Level::Info, "• ", message, fields, :default, @depth)
    end

    def warn(message : String, **fields) : Nil
      write(Level::Warn, "⚠ ", message, fields, :yellow, @depth)
    end

    def error(message : String, **fields) : Nil
      write(Level::Error, "⨯ ", message, fields, :red, @depth)
    end

    # Debug lines are indented one level deeper than the current depth and
    # carry no bullet: they read as detail of the line above. The depth is
    # passed along rather than bumped: builds call this from parallel fibers,
    # and `@depth` only ever changes in `nest`, on the fiber of the pipeline.
    def debug(message : String, **fields) : Nil
      write(Level::Debug, "", message, fields, :dark_gray, @depth + 1)
    end

    def nest(& : ->) : Nil
      @depth += 1
      yield
    ensure
      @depth -= 1
    end

    private def write(level : Level, bullet : String, message : String, fields, color : Symbol, depth : Int32) : Nil
      return if level < @level
      line = String.build do |io|
        io << message
        fields.each { |key, value| io << ' ' << key << '=' << value }
      end
      text = "#{bullet}#{line}"
      # `toggle` overrides the global Colorize.enabled?, which only looks at
      # STDOUT/STDERR and would ignore the stream actually written to.
      styled = text.colorize.toggle(@color)
      styled = color == :default ? (depth == 0 ? styled.bold : styled) : styled.fore(color)
      @mutex.synchronize do
        @io << "  " * depth << styled << '\n'
        @io.flush
      end
    end
  end
end
