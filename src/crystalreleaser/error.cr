module Crystalreleaser
  # Root of every error crystalreleaser raises on purpose. The CLI rescues this
  # class alone: it prints the message and exits 1, with the backtrace only
  # under --verbose. Anything else escaping is a bug and keeps its backtrace.
  class Error < Exception
  end

  # Wrong command line: unknown command or option, conflicting flags.
  class UsageError < Error
  end

  # Configuration that cannot be loaded or does not validate.
  class ConfigError < Error
  end

  # Malformed template, unknown variable or function, or a value missing at
  # render time. The message starts with the config field it came from.
  class TemplateError < Error
  end

  # A git command failed, or the repository is not in a releasable state.
  class GitError < Error
  end

  # A binary could not be built.
  class BuildError < Error
  end

  # A file format (tar, ar, cpio, rpm) cannot represent the input.
  class FormatError < Error
  end

  # An archive, checksum or package could not be produced.
  class PackageError < Error
  end

  # A `before.hooks` command failed.
  class HookError < Error
  end
end
