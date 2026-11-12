require "../error"

module Crystalreleaser
  module Formats
    # The common Unix `ar` format, as .deb uses it: an `!<arch>` signature,
    # then for each member a 60-byte text header and the data, padded to an
    # even size with a newline. Owner 0:0, mode 0100644, like dpkg-deb.
    module Ar
      MAGIC = "!<arch>\n"

      record Member, name : String, mtime : Time, mode : Int32, content : Bytes

      class Writer
        def initialize(@io : IO)
          @io << MAGIC
        end

        def add(name : String, content : Bytes, mtime : Time, mode : Int32 = 0o100644) : Nil
          raise FormatError.new("ar member name longer than 16 bytes: #{name}") if name.bytesize > 16
          # Padded by hand: `ljust` counts characters, the field is 16 bytes.
          @io << name << " " * (16 - name.bytesize)
          @io << mtime.to_unix.to_s.ljust(12)
          @io << "0".ljust(6) << "0".ljust(6)
          @io << mode.to_s(8).ljust(8)
          @io << content.size.to_s.ljust(10)
          @io << "`\n"
          @io.write(content)
          @io << '\n' if content.size.odd?
        end
      end

      def self.read(io : IO) : Array(Member)
        magic = Bytes.new(MAGIC.bytesize)
        io.read_fully(magic)
        raise FormatError.new("not an ar archive") unless String.new(magic) == MAGIC
        members = [] of Member
        header = Bytes.new(60)
        while io.read(header[0, 1]) == 1
          io.read_fully(header + 1)
          # Fields are byte ranges: sliced as bytes, since a name may not be
          # ASCII.
          field = ->(offset : Int32, width : Int32) { String.new(header[offset, width]).strip }
          size = field.call(48, 10).to_i
          content = Bytes.new(size)
          io.read_fully(content)
          io.skip(1) if size.odd?
          members << Member.new(field.call(0, 16).rchop('/'), Time.unix(field.call(16, 12).to_i64),
            field.call(40, 8).to_i(8), content)
        end
        members
      end
    end
  end
end
