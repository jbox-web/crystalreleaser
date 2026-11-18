require "../error"

module Crystalreleaser
  module Formats
    # cpio "newc" (SVR4, no CRC), the payload format of RPM: a 110-byte
    # header of "070701" and thirteen 8-digit hex fields, the NUL-terminated
    # name, then the data, header+name and data each padded to 4 bytes. Ends
    # with a TRAILER!!! entry.
    module Cpio
      MAGIC   = "070701"
      TRAILER = "TRAILER!!!"

      record Entry, name : String, mode : Int32, uid : Int32, gid : Int32, mtime : Time, ino : Int32, content : Bytes

      class Writer
        getter written : Int64 = 0_i64

        def initialize(@io : IO)
          @ino = 0
        end

        # A regular file; `mode` is the permission bits only.
        def add_file(name : String, mode : Int32, mtime : Time, path : String) : Nil
          @ino += 1
          size = File.size(path)
          raise FormatError.new("file too large for cpio newc: #{name}") if size > UInt32::MAX
          header(name, 0o100000 | (mode & 0o7777), @ino, 1, mtime.to_unix, size)
          File.open(path) { |file| @written += IO.copy(file, @io) }
          pad(size)
        end

        # A directory; `mode` is the permission bits only.
        def add_directory(name : String, mode : Int32, mtime : Time) : Nil
          @ino += 1
          header(name, 0o040000 | (mode & 0o7777), @ino, 2, mtime.to_unix, 0_i64)
        end

        # A symbolic link: mode 0120777, and the target as its data, as
        # rpmbuild writes one in a payload.
        def add_symlink(name : String, target : String, mtime : Time) : Nil
          @ino += 1
          header(name, 0o120777, @ino, 1, mtime.to_unix, target.bytesize.to_i64)
          write(target.to_slice)
          pad(target.bytesize.to_i64)
        end

        def close : Nil
          header(TRAILER, 0, 0, 1, 0_i64, 0_i64)
        end

        private def header(name : String, mode : Int32, ino : Int32, nlink : Int32, mtime : Int64, size : Int64) : Nil
          # Each field is 8 hexadecimal digits: one more shifts all the rest.
          unless 0 <= mtime <= UInt32::MAX
            raise FormatError.new("a cpio archive cannot hold a date before 1970 or after 2106")
          end
          fields = [ino, mode, 0, 0, nlink, mtime, size, 0, 0, 0, 0, name.bytesize + 1, 0]
          text = String.build do |str|
            str << MAGIC
            fields.each { |field| str << field.to_s(16).rjust(8, '0') }
            str << name << '\0'
          end
          write(text.to_slice)
          pad(text.bytesize.to_i64)
        end

        private def pad(size : Int64) : Nil
          remainder = size % 4
          write(Bytes.new(4 - remainder)) unless remainder.zero?
        end

        private def write(bytes : Bytes) : Nil
          @io.write(bytes)
          @written += bytes.size
        end
      end

      # Every entry before the trailer.
      def self.read(io : IO) : Array(Entry)
        entries = [] of Entry
        loop do
          header = Bytes.new(110)
          io.read_fully(header)
          text = String.new(header)
          raise FormatError.new("bad cpio magic") unless text.starts_with?(MAGIC)
          field = ->(index : Int32) { text[6 + index * 8, 8].to_i64(16) }
          name_size = field.call(11).to_i
          name_bytes = Bytes.new(name_size)
          io.read_fully(name_bytes)
          io.skip((4 - (110 + name_size) % 4) % 4)
          name = String.new(name_bytes[0, name_size - 1])
          break if name == TRAILER
          size = field.call(6)
          content = Bytes.new(size)
          io.read_fully(content)
          io.skip((4 - size % 4) % 4)
          entries << Entry.new(name, field.call(1).to_i, field.call(2).to_i, field.call(3).to_i,
            Time.unix(field.call(5)), field.call(0).to_i, content)
        end
        entries
      end
    end
  end
end
