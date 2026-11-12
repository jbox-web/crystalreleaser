require "../error"

module Crystalreleaser
  module Formats
    # Where a writer builds what it must measure or hash before writing it
    # out: a compressed zip member, the payload of a package. It is an
    # IO::Memory that refuses, naming the thing, what IO::Memory cannot hold:
    # past 2 GiB that one raises an end-of-file error that says nothing.
    class Buffer < IO
      LIMIT = Int32::MAX.to_i64

      def initialize(@what : String, *, @limit : Int64 = LIMIT)
        @io = IO::Memory.new
      end

      def write(slice : Bytes) : Nil
        if @io.size.to_i64 + slice.size > @limit
          raise FormatError.new("#{@what} is too large once compressed: it is built in memory, which holds 2 GiB at most")
        end
        @io.write(slice)
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("a format buffer is write-only")
      end

      def to_slice : Bytes
        @io.to_slice
      end
    end
  end
end
