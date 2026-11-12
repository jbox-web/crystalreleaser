require "compress/deflate"
require "digest/crc32"

require "../error"
require "./buffer"

module Crystalreleaser
  module Formats
    # A zip archive (APPNOTE 6.3), written by hand because the stdlib writer
    # stores neither Unix permissions (a binary extracted from its archives
    # is not executable) nor a caller-given time for directories (its
    # archives differ from one run to the next).
    #
    # Deflate, no zip64: an entry or an archive of 4 GiB is refused, and so
    # is an entry whose compressed data, built in memory, passes 2 GiB. Names
    # are UTF-8 (general purpose bit 11). The Unix mode goes in the high 16
    # bits of the external attributes, which is where unzip reads it when
    # "version made by" names Unix.
    module Zip
      LOCAL_HEADER   = 0x04034b50_u32
      CENTRAL_HEADER = 0x02014b50_u32
      END_OF_CENTRAL = 0x06054b50_u32
      VERSION_NEEDED =         20_u16
      # Host system 3 (Unix) in the high byte, specification 2.0 in the low.
      VERSION_MADE_BY = (3_u16 << 8) | 20_u16
      UTF8_NAMES      = 0x0800_u16
      STORED          =      0_u16
      DEFLATED        =      8_u16
      MSDOS_DIRECTORY =   0x10_u32

      private record Entry, name : String, method : UInt16, time : UInt16, date : UInt16, crc : UInt32,
        compressed : UInt32, size : UInt32, attributes : UInt32, offset : UInt32

      class Writer
        def initialize(@io : IO)
          @entries = [] of Entry
          @offset = 0_i64
        end

        # A directory; `mode` is the permission bits only.
        def add_directory(name : String, mode : Int32, mtime : Time) : Nil
          name = name.ends_with?('/') ? name : "#{name}/"
          attributes = ((0o040000 | (mode & 0o7777)).to_u32 << 16) | MSDOS_DIRECTORY
          add(name, STORED, mtime, 0_u32, Bytes.empty, 0_i64, attributes)
        end

        # A regular file; `mode` is the permission bits only.
        def add_file(name : String, mode : Int32, mtime : Time, path : String) : Nil
          crc = Digest::CRC32.initial
          size = 0_i64
          data = Buffer.new(name)
          Compress::Deflate::Writer.open(data) do |deflate|
            File.open(path) do |file|
              buffer = Bytes.new(64 * 1024)
              while (read = file.read(buffer)) > 0
                crc = Digest::CRC32.update(buffer[0, read], crc)
                size += read
                deflate.write(buffer[0, read])
              end
            end
          end
          add(name, DEFLATED, mtime, crc, data.to_slice, size, (0o100000 | (mode & 0o7777)).to_u32 << 16)
        end

        # The central directory and its end record.
        def close : Nil
          start = @offset
          @entries.each { |entry| header(CENTRAL_HEADER, entry) }
          # The maximum of each field is not a value: it says "see the zip64
          # record", which is not written here.
          raise FormatError.new("too many entries for a zip archive without zip64") if @entries.size >= UInt16::MAX
          size = @offset - start
          write(END_OF_CENTRAL)
          write(0_u16)
          write(0_u16)
          write(@entries.size.to_u16)
          write(@entries.size.to_u16)
          write(uint32(size, "the zip central directory"))
          write(uint32(start, "the zip archive"))
          write(0_u16)
        end

        private def add(name : String, method : UInt16, mtime : Time, crc : UInt32, data : Bytes, size : Int64,
                        attributes : UInt32) : Nil
          raise FormatError.new("name too long for a zip archive: #{name}") if name.bytesize > UInt16::MAX
          time, date = dos_time(mtime)
          entry = Entry.new(name, method, time, date, crc, uint32(data.size, name), uint32(size, name), attributes,
            uint32(@offset, "the zip archive"))
          header(LOCAL_HEADER, entry)
          @io.write(data)
          @offset += data.size
          @entries << entry
        end

        # The local and the central header share most of their fields.
        private def header(signature : UInt32, entry : Entry) : Nil
          central = signature == CENTRAL_HEADER
          write(signature)
          write(VERSION_MADE_BY) if central
          write(VERSION_NEEDED)
          write(UTF8_NAMES)
          write(entry.method)
          write(entry.time)
          write(entry.date)
          write(entry.crc)
          write(entry.compressed)
          write(entry.size)
          write(entry.name.bytesize.to_u16)
          # extra field length
          write(0_u16)
          if central
            # comment length, disk number, internal attributes
            write(0_u16)
            write(0_u16)
            write(0_u16)
            write(entry.attributes)
            write(entry.offset)
          end
          @io.write(entry.name.to_slice)
          @offset += entry.name.bytesize
        end

        # MS-DOS time and date, from the UTC fields: 2-second resolution,
        # nothing before 1980.
        private def dos_time(time : Time) : {UInt16, UInt16}
          utc = time.to_utc
          raise FormatError.new("a zip archive cannot hold a date before 1980 or after 2107") unless 1980 <= utc.year <= 2107
          {((utc.hour << 11) | (utc.minute << 5) | (utc.second // 2)).to_u16,
           (((utc.year - 1980) << 9) | (utc.month << 5) | utc.day).to_u16}
        end

        private def uint32(value : Int, what : String) : UInt32
          raise FormatError.new("#{what} is too large for a zip archive without zip64 (4 GiB limit)") if value >= UInt32::MAX
          value.to_u32
        end

        private def write(value : UInt16) : Nil
          @io.write_bytes(value, IO::ByteFormat::LittleEndian)
          @offset += 2
        end

        private def write(value : UInt32) : Nil
          @io.write_bytes(value, IO::ByteFormat::LittleEndian)
          @offset += 4
        end
      end
    end
  end
end
