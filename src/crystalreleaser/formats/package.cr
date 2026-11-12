module Crystalreleaser
  module Formats
    # What a Linux package holds, independent of its format.
    class PackageSpec
      # What a package manager does with a file on upgrade. A configuration
      # file the administrator changed is not silently overwritten: dpkg asks
      # or keeps it, rpm saves it as .rpmsave, or with ConfigNoreplace keeps
      # it and installs the new one as .rpmnew.
      enum Kind
        Regular
        Config
        ConfigNoreplace

        def config? : Bool
          !regular?
        end
      end

      # An installed file: absolute destination, source on disk, mode.
      record File, dst : String, src : String, mode : Int32, kind : Kind = Kind::Regular

      property name : String
      # The upstream version, semver: 1.2.3-rc.1.
      property version : String
      # Go-style architecture: amd64 | arm64.
      property arch : String
      property maintainer : String = ""
      property description : String = ""
      property homepage : String = ""
      property license : String = ""
      property vendor : String = ""
      property section : String = "utils"
      property priority : String = "optional"
      property dependencies : Array(String) = [] of String
      property files : Array(File) = [] of File
      property mtime : Time = Time.unix(0)

      def initialize(@name : String, @version : String, @arch : String)
      end

      # Directories every system already has: a package installs into them
      # but does not own them.
      SYSTEM_DIRECTORIES = %w[
        /bin /sbin /lib /lib64 /etc /opt /var /var/lib /var/log /var/cache
        /usr /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec /usr/include
        /usr/local /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/share
        /usr/share /usr/share/doc /usr/share/man /usr/share/licenses /usr/share/applications
        /usr/share/bash-completion /usr/share/bash-completion/completions
        /usr/share/zsh /usr/share/zsh/site-functions
        /usr/share/fish /usr/share/fish/vendor_completions.d
        /etc/systemd /etc/systemd/system /usr/lib/systemd /usr/lib/systemd/system
      ]

      # The first line of the description, the package summary.
      def summary : String
        description.strip.lines.first?.try(&.strip).presence || name
      end

      # The directories that only exist because of this package.
      def owned_directories : Array(String)
        directories.reject { |dir| SYSTEM_DIRECTORIES.includes?(dir) || dir.matches?(%r{\A/usr/share/man/man\w+\z}) }
      end

      # A dependency as {name, operator, version}; operator and version are
      # empty without a constraint. Both spellings are read, so one list
      # serves both formats: rpm's `name >= 1.0` (spaces optional) and
      # Debian's `name (>= 1.0)`, whose strict `<<` and `>>` are returned as
      # `<` and `>`. Anything else (alternatives, rich dependencies) is
      # returned whole as the name.
      def self.parse_dependency(text : String) : {String, String, String}
        match = text.strip.match(/\A([^\s<>=()|]+)\s*\(?\s*(<<|>>|<=|>=|<|>|=)\s*([^\s()]+)\s*\)?\z/)
        return {text.strip, "", ""} unless match
        operator = {"<<" => "<", ">>" => ">"}[match[2]]? || match[2]
        {match[1], operator, match[3]}
      end

      def installed_size : Int64
        files.sum(0_i64) { |file| ::File.size(file.src) }
      end

      # Every directory leading to the files, shortest first, without "/".
      def directories : Array(String)
        dirs = Set(String).new
        files.each do |file|
          parts = file.dst.split('/').reject(&.empty?)
          (1...parts.size).each { |depth| dirs << "/" + parts[0, depth].join('/') }
        end
        dirs.to_a.sort!
      end

      # deb and rpm both forbid '-' in the upstream version, and sort a '~'
      # before the release: 1.2.3-rc.1 becomes 1.2.3~rc.1, which sorts
      # before 1.2.3 as semver wants. Every hyphen goes: a snapshot version
      # (1.2.4-SNAPSHOT-abc1234) has two.
      def package_version : String
        version.gsub('-', '~')
      end
    end
  end
end
