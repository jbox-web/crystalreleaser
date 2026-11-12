require "./error"

module Crystalreleaser
  # A deliberately minimal template engine, not Go templates:
  #
  #   {{ .Version }}                  a variable
  #   {{ .Env.HOMEBREW_TAP_TOKEN }}   an environment variable
  #   {{ "{{" }}                      a quoted string, written as it is: the
  #                                   way to get a literal {{ or }}
  #   {{ .Tag | trimprefix "v" }}     filters: upper, lower, replace "a" "b",
  #                                   trimprefix "x", trimsuffix "x",
  #                                   shellquote
  #
  # Values are inserted as they are. In a command run by a shell (the before
  # hooks), a value that comes from git (.Branch, .Tag, .PreviousTag) or
  # from the environment must go through `shellquote`.
  #
  # Unknown names are rejected at parse time, so `crystalreleaser check` finds
  # them without rendering anything. Every error names the config field the
  # template came from.
  class Template
    # Every variable the engine knows. Which of them a given field can use
    # depends on the field: a per-platform name such as `.Os` only exists
    # where a platform does, which `render` and `check_available` enforce.
    VARIABLES = %w[
      ProjectName Version RawVersion Tag PreviousTag Major Minor Patch
      Prerelease Commit ShortCommit Branch Date Timestamp Os Arch Target
      Binary PackageName CrystalVersion IsSnapshot
    ]

    # Filter name => number of string arguments.
    FILTERS = {
      "upper"      => 0,
      "lower"      => 0,
      "replace"    => 2,
      "trimprefix" => 1,
      "trimsuffix" => 1,
      "shellquote" => 0,
    }

    record Filter, name : String, args : Array(String)

    # `env` is true for `.Env.NAME`, in which case `name` is NAME.
    record Action, name : String, env : Bool, filters : Array(Filter)

    alias Node = String | Action

    getter field : String

    def self.parse(source : String, field : String) : Template
      new(source, field)
    end

    # Parses and renders in one go.
    def self.render(source : String, field : String, vars : Hash(String, String), env = ENV) : String
      parse(source, field).render(vars, env)
    end

    def initialize(source : String, @field : String)
      @nodes = [] of Node
      parse(source)
    end

    # The variable names used, without `.Env.*`.
    def variables : Array(String)
      @nodes.compact_map { |node| node.name if node.is_a?(Action) && !node.env }.uniq!
    end

    # Raises unless every variable used is in `available`: the static half of
    # the check `render` performs, for `crystalreleaser check`.
    def check_available(available : Enumerable(String)) : Nil
      missing = variables.find { |name| !available.includes?(name) }
      raise error("variable .#{missing} is not available here") if missing
    end

    def render(vars : Hash(String, String), env = ENV) : String
      String.build do |io|
        @nodes.each do |node|
          case node
          in String then io << node
          in Action then io << evaluate(node, vars, env)
          end
        end
      end
    end

    private def evaluate(action : Action, vars : Hash(String, String), env) : String
      value =
        if action.env
          env[action.name]? || raise error("environment variable #{action.name} is not set")
        else
          vars[action.name]? || raise error("variable .#{action.name} is not available here")
        end
      action.filters.reduce(value) { |acc, filter| apply(filter, acc) }
    end

    private def apply(filter : Filter, value : String) : String
      args = filter.args
      case filter.name
      when "upper"      then value.upcase
      when "lower"      then value.downcase
      when "replace"    then value.gsub(args[0], args[1])
      when "trimprefix" then value.lchop(args[0])
      when "trimsuffix" then value.rchop(args[0])
      when "shellquote" then Process.quote_posix(value)
      else                   raise error("unknown function #{filter.name}")
      end
    end

    private def parse(source : String) : Nil
      position = 0
      while open = source.index("{{", position)
        @nodes << source[position...open] if open > position
        close = closing(source, open + 2) || raise error("unclosed action, missing '}}'")
        @nodes << parse_action(source[(open + 2)...close])
        position = close + 2
      end
      @nodes << source[position..] if position < source.size
    end

    # The index of the `}}` that ends the action starting at `from`: the
    # first one that is not inside a quoted string.
    private def closing(source : String, from : Int32) : Int32?
      quoted = false
      escaped = false
      previous = nil
      source.each_char_with_index do |char, index|
        next if index < from
        if quoted
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            quoted = false
          end
          previous = nil
        elsif char == '"'
          quoted = true
          previous = nil
        elsif char == '}' && previous == '}'
          return index - 1
        else
          previous = char
        end
      end
      nil
    end

    private def parse_action(body : String) : Node
      tokens = tokenize(body)
      head = tokens.shift? || raise error("empty action")
      if head.starts_with?('"')
        raise error("a quoted string takes no function") unless tokens.empty?
        return unquote(head)
      end
      unless head.starts_with?('.') && head.size > 1
        raise error("expected a variable such as .Version, got '#{head}'")
      end

      path = head[1..].split('.')
      action =
        if path.size == 2 && path[0] == "Env" && !path[1].empty?
          Action.new(path[1], true, [] of Filter)
        elsif path.size == 1 && VARIABLES.includes?(path[0])
          Action.new(path[0], false, [] of Filter)
        else
          raise error("unknown variable #{head}")
        end

      parse_filters(tokens, action.filters)
      action
    end

    private def parse_filters(tokens : Array(String), filters : Array(Filter)) : Nil
      until tokens.empty?
        pipe = tokens.shift
        raise error("expected '|', got '#{pipe}'") unless pipe == "|"
        name = tokens.shift? || raise error("missing function name after '|'")
        arity = FILTERS[name]? || raise error("unknown function #{name}")

        args = [] of String
        while (token = tokens.first?) && token != "|"
          tokens.shift
          raise error("function #{name} expects quoted arguments, got '#{token}'") unless token.starts_with?('"')
          args << unquote(token)
        end
        raise error("function #{name} takes #{arity} argument(s), got #{args.size}") unless args.size == arity
        filters << Filter.new(name, args)
      end
    end

    # Splits on whitespace, keeping double-quoted strings (with their quotes,
    # backslash escapes preserved) and `|` as tokens of their own.
    private def tokenize(body : String) : Array(String)
      tokens = [] of String
      reader = Char::Reader.new(body)
      while reader.has_next?
        char = reader.current_char
        if char.whitespace?
          reader.next_char
        elsif char == '|'
          tokens << "|"
          reader.next_char
        elsif char == '"'
          # Char::Reader is a struct: the helper gets a copy, so it hands the
          # advanced reader back rather than mutating ours.
          token, reader = read_quoted(reader)
          tokens << token
        else
          start = reader.pos
          while reader.has_next? && !reader.current_char.whitespace? && !reader.current_char.in?('|', '"')
            reader.next_char
          end
          # Char::Reader counts in bytes, String#[] in characters.
          tokens << body.byte_slice(start, reader.pos - start)
        end
      end
      tokens
    end

    private def read_quoted(reader : Char::Reader) : {String, Char::Reader}
      token = String.build do |io|
        io << reader.current_char
        reader.next_char
        loop do
          raise error("unterminated string") unless reader.has_next?
          char = reader.current_char
          io << char
          reader.next_char
          if char == '\\'
            raise error("unterminated string") unless reader.has_next?
            io << reader.current_char
            reader.next_char
          elsif char == '"'
            break
          end
        end
      end
      {token, reader}
    end

    ESCAPES = {'n' => '\n', 't' => '\t', '\\' => '\\', '"' => '"'}

    # The text of a quoted string. An escape that is not known is an error:
    # dropping its backslash would turn "\d" into "d" without a word.
    private def unquote(token : String) : String
      String.build do |io|
        escaped = false
        token[1...-1].each_char do |char|
          if escaped
            io << (ESCAPES[char]? || raise error(%(unknown escape \\#{char} in a string (known: \\n, \\t, \\\\, \\"))))
            escaped = false
          elsif char == '\\'
            escaped = true
          else
            io << char
          end
        end
      end
    end

    private def error(message : String) : TemplateError
      TemplateError.new("#{@field}: #{message}")
    end
  end
end
