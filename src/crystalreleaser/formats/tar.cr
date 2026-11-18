require "../error"

module Crystalreleaser
  module Formats
    # POSIX ustar, written field for field like GNU tar --format=ustar: octal
    # numbers zero-padded and NUL-terminated, checksum as six digits, NUL and
    # space, empty device numbers. Owner is always root:0 so archives do not
    # leak the builder's account and are reproducible.
    module Tar
      BLOCK = 512

      # A member read back by `Tar.read`, which only the specs use.
      record Entry, name : String, mode : Int32, uid : Int32, gid : Int32, uname : String, gname : String,
        mtime : Time, type : Char, content : Bytes

      class Writer
        def initialize(@io : IO)
        end

        def add_directory(name : String, mtime : Time, mode : Int32 = 0o755) : Nil
          name = name.ends_with?('/') ? name : "#{name}/"
          write_header(name, mode, 0_i64, mtime, '5')
        end

        # A symbolic link to `target`, which is stored as given (a relative
        # name stays valid wherever the archive is extracted). Mode 0777 like
        # GNU tar writes for a link; no data block follows.
        def add_symlink(name : String, target : String, mtime : Time) : Nil
          write_header(name, 0o777, 0_i64, mtime, '2', target)
        end

        def add_file(name : String, mode : Int32, mtime : Time, content : Bytes) : Nil
          write_header(name, mode, content.size.to_i64, mtime, '0')
          @io.write(content)
          pad(content.size.to_i64)
        end

        # Streams a file from disk without loading it in memory.
        def add_file(name : String, mode : Int32, mtime : Time, path : String) : Nil
          size = File.size(path)
          write_header(name, mode, size, mtime, '0')
          File.open(path) { |file| IO.copy(file, @io) }
          pad(size)
        end

        # The end-of-archive marker: two zero blocks.
        def close : Nil
          @io.write(Bytes.new(BLOCK * 2))
        end

        private def pad(size : Int64) : Nil
          remainder = size % BLOCK
          @io.write(Bytes.new(BLOCK - remainder)) unless remainder.zero?
        end

        private def write_header(name : String, mode : Int32, size : Int64, mtime : Time, type : Char, link : String = "") : Nil
          prefix, short = Tar.split_name(name)
          raise FormatError.new("file too large for a ustar archive: #{name}") if size >= 8_i64 ** 11
          raise FormatError.new("a tar archive cannot hold a time before 1970: #{name}") if mtime.to_unix < 0

          header = Bytes.new(BLOCK)
          put(header, 0, 100, short)
          put(header, 100, 8, Tar.octal(mode & 0o7777, 7))
          put(header, 108, 8, Tar.octal(0, 7))
          put(header, 116, 8, Tar.octal(0, 7))
          put(header, 124, 12, Tar.octal(size, 11))
          put(header, 136, 12, Tar.octal(mtime.to_unix, 11))
          header[156] = type.ord.to_u8
          put(header, 157, 100, link)
          put(header, 257, 6, "ustar")
          put(header, 263, 2, "00")
          put(header, 265, 32, "root")
          put(header, 297, 32, "root")
          put(header, 345, 155, prefix)

          # The checksum is computed with its own field filled with spaces.
          (148...156).each { |index| header[index] = ' '.ord.to_u8 }
          sum = header.sum(0_i64, &.to_i64)
          put(header, 148, 8, "#{sum.to_s(8).rjust(6, '0')}\0 ")
          @io.write(header)
        end

        private def put(header : Bytes, offset : Int32, width : Int32, value : String) : Nil
          bytes = value.to_slice
          raise FormatError.new("tar field overflow: #{value}") if bytes.size > width
          bytes.copy_to(header + offset)
        end
      end

      # `value` in octal on `digits` digits, NUL-terminated.
      def self.octal(value : Int, digits : Int32) : String
        "#{value.to_s(8).rjust(digits, '0')}\0"
      end

      # ustar stores up to 100 bytes of name, plus up to 155 of prefix split
      # at a '/'.
      def self.split_name(name : String) : {String, String}
        return {"", name} if name.bytesize <= 100
        index = name.size
        while index = name.rindex('/', index - 1)
          prefix, short = name[0...index], name[(index + 1)..]
          # An empty prefix is the split at the first slash of an absolute
          # path, which would lose that slash.
          return {prefix, short} if !prefix.empty? && prefix.bytesize <= 155 && short.bytesize <= 100 && !short.empty?
          break if index.zero?
        end
        raise FormatError.new("path too long for a ustar archive: #{name}")
      end

      # Reads every member of an uncompressed archive.
      def self.read(io : IO) : Array(Entry)
        entries = [] of Entry
        header = Bytes.new(BLOCK)
        loop do
          io.read_fully(header)
          break if header.all?(&.zero?)
          size = field(header, 124, 12).to_i64(8)
          content = Bytes.new(size)
          io.read_fully(content)
          remainder = size % BLOCK
          io.skip(BLOCK - remainder) unless remainder.zero?

          prefix = field(header, 345, 155)
          name = field(header, 0, 100)
          entries << Entry.new(
            prefix.empty? ? name : "#{prefix}/#{name}",
            field(header, 100, 8).to_i(8), field(header, 108, 8).to_i(8), field(header, 116, 8).to_i(8),
            field(header, 265, 32), field(header, 297, 32),
            Time.unix(field(header, 136, 12).to_i64(8)), header[156].chr, content)
        end
        entries
      end

      private def self.field(header : Bytes, offset : Int32, width : Int32) : String
        slice = header[offset, width]
        length = slice.index(0_u8) || width
        String.new(slice[0, length]).strip
      end
    end
  end
end
