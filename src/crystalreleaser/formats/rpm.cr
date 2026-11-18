require "compress/gzip"
require "digest/md5"
require "digest/sha1"
require "digest/sha256"

require "../error"
require "./buffer"
require "./cpio"
require "./package"

module Crystalreleaser
  module Formats
    # A binary RPM (v3 lead, v4 headers), written without rpmbuild:
    #
    #   lead (96 bytes) | signature header, padded to 8 | main header | payload
    #
    # The payload is a gzip-compressed cpio newc archive. The signature header
    # carries the SHA1 and SHA256 of the main header, and the MD5 and size of
    # header + payload, which is what `rpm -K` checks.
    #
    # Given a signer, it also carries an OpenPGP signature of the main header,
    # under RSAHEADER or DSAHEADER: the tags rpm 4 and rpm 6 both read. That
    # one signature covers the payload too, since the signed header holds the
    # payload digest: rpm counts a digest found in a signed header as signed
    # (lib/rpmvs.cc, "Digests in signed header are signature strength"), and
    # rpmsign itself adds a header + payload signature only to a package
    # without that digest. rpm 6 (Fedora 43+) installs nothing else by
    # default: its `%_pkgverify_level` is `all`.
    module Rpm
      HEADER_MAGIC = Bytes[0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0]
      LEAD_MAGIC   = Bytes[0xed, 0xab, 0xee, 0xdb]

      # Value types of header entries.
      enum Type
        Null        = 0
        Char        = 1
        Int8        = 2
        Int16       = 3
        Int32       = 4
        Int64       = 5
        String      = 6
        Bin         = 7
        StringArray = 8
        I18nString  = 9
      end

      # Tags used here (rpmtag.h).
      module Tag
        HEADERSIGNATURES  =   62
        HEADERIMMUTABLE   =   63
        HEADERI18NTABLE   =  100
        SIG_DSA           =  267
        SIG_RSA           =  268
        SIG_SHA1          =  269
        SIG_SHA256        =  273
        SIG_SIZE          = 1000
        SIG_MD5           = 1004
        SIG_PAYLOADSIZE   = 1007
        NAME              = 1000
        VERSION           = 1001
        RELEASE           = 1002
        SUMMARY           = 1004
        DESCRIPTION       = 1005
        BUILDTIME         = 1006
        BUILDHOST         = 1007
        SIZE              = 1009
        VENDOR            = 1011
        LICENSE           = 1014
        PACKAGER          = 1015
        GROUP             = 1016
        URL               = 1020
        OS                = 1021
        ARCH              = 1022
        FILESIZES         = 1028
        FILEMODES         = 1030
        FILERDEVS         = 1033
        FILEMTIMES        = 1034
        FILEDIGESTS       = 1035
        FILELINKTOS       = 1036
        FILEFLAGS         = 1037
        FILEUSERNAME      = 1039
        FILEGROUPNAME     = 1040
        SOURCERPM         = 1044
        FILEVERIFYFLAGS   = 1045
        PROVIDENAME       = 1047
        REQUIREFLAGS      = 1048
        REQUIRENAME       = 1049
        REQUIREVERSION    = 1050
        RPMVERSION        = 1064
        FILEDEVICES       = 1095
        FILEINODES        = 1096
        FILELANGS         = 1097
        PROVIDEFLAGS      = 1112
        PROVIDEVERSION    = 1113
        DIRINDEXES        = 1116
        BASENAMES         = 1117
        DIRNAMES          = 1118
        PAYLOADFORMAT     = 1124
        PAYLOADCOMPRESSOR = 1125
        PAYLOADFLAGS      = 1126
        FILEDIGESTALGO    = 5011
        PAYLOADDIGEST     = 5092
        PAYLOADDIGESTALGO = 5093
        PAYLOADDIGESTALT  = 5097
      end

      # Dependency comparison flags (rpmds.h).
      SENSE_LESS    = 1 << 1
      SENSE_GREATER = 1 << 2
      SENSE_EQUAL   = 1 << 3
      SENSE_RPMLIB  = 1 << 24

      # What every binary package built this way relies on.
      RPMLIB_REQUIRES = [
        {"rpmlib(CompressedFileNames)", "3.0.4-1"},
        {"rpmlib(FileDigests)", "4.6.0-1"},
        {"rpmlib(PayloadFilesHavePrefix)", "4.0-1"},
      ]

      ARCHES     = {"amd64" => "x86_64", "arm64" => "aarch64"}
      LEAD_ARCHS = {"x86_64" => 1_i16, "aarch64" => 19_i16}
      RELEASE    = "1"

      alias Value = String | Array(String) | Array(Int16) | Array(Int32) | Bytes

      record Entry, tag : Int32, type : Type, value : Value

      # Given the bytes to sign, returns their detached OpenPGP signature as
      # one binary packet.
      alias Signer = Proc(Bytes, Bytes)

      # The signature header tag an OpenPGP signature of the main header goes
      # under.
      def self.signature_tag(packet : Bytes) : Int32
        body = signature_packet_body(packet)
        # RFC 4880, 5.2.3: version, signature type, public-key algorithm.
        version = body[0]
        algorithm = body[2]
        unless version == 4
          raise FormatError.new("an RPM package cannot hold an OpenPGP v#{version} signature (v4 only)")
        end
        case algorithm
        when 1          then Tag::SIG_RSA
        when 17, 19, 22 then Tag::SIG_DSA
        else
          raise FormatError.new("an RPM package cannot hold a signature of OpenPGP public-key algorithm #{algorithm} " \
                                "(RSA, DSA, ECDSA and EdDSA only)")
        end
      end

      # The body of a signature packet (tag 2), past its header in either
      # format (RFC 4880, 4.2).
      private def self.signature_packet_body(packet : Bytes) : Bytes
        error = FormatError.new("not an OpenPGP signature packet")
        first = packet[0]? || raise error
        raise error if first & 0x80 == 0
        if first & 0x40 != 0
          tag = first & 0x3f
          length = packet[1]? || raise error
          skipped =
            case length
            when 0..191   then 2
            when 192..223 then 3
            when 255      then 6
            else               raise error
            end
        else
          tag = (first >> 2) & 0x0f
          skipped = {2, 3, 5, 1}[first & 0x03]
        end
        raise error unless tag == 2 && packet.size >= skipped + 4
        packet[skipped..]
      end

      def self.write(io : IO, spec : PackageSpec, sign : Signer? = nil) : Nil
        arch = ARCHES[spec.arch]? || raise FormatError.new("no RPM architecture for #{spec.arch}")
        payload, payload_size, uncompressed_sha256 = payload(spec)
        entries = main_entries(spec, arch)
        # rpm >= 4.14 checks these, and rpm 6 (Fedora 43+) refuses a package
        # without them: the legacy MD5 of the signature header is not enough.
        entries.concat([
          Entry.new(Tag::PAYLOADDIGEST, Type::StringArray, [Digest::SHA256.hexdigest(payload)]),
          Entry.new(Tag::PAYLOADDIGESTALGO, Type::Int32, [8]),
          Entry.new(Tag::PAYLOADDIGESTALT, Type::StringArray, [uncompressed_sha256]),
        ])
        header = header(entries.sort_by!(&.tag), Tag::HEADERIMMUTABLE)
        signature = header(signature_entries(header, payload, payload_size, sign), Tag::HEADERSIGNATURES)

        io.write(lead(spec, arch))
        io.write(signature)
        io.write(Bytes.new((8 - signature.size % 8) % 8))
        io.write(header)
        io.write(payload)
      end

      # Gzip-compressed cpio of the files, its uncompressed size, and the
      # SHA256 of the uncompressed cpio.
      private def self.payload(spec : PackageSpec) : {Bytes, Int64, String}
        io = Buffer.new("the content of the .rpm package")
        gzip = Compress::Gzip::Writer.new(io, level: Compress::Gzip::BEST_COMPRESSION)
        gzip.header.modification_time = spec.mtime
        digest = Digest::SHA256.new
        cpio = Cpio::Writer.new(IO::MultiWriter.new(gzip, DigestWriter.new(digest)))
        items(spec).each do |item|
          if link = item.link
            cpio.add_symlink(".#{item.dst}", link, spec.mtime)
          elsif source = item.src
            cpio.add_file(".#{item.dst}", item.mode, spec.mtime, source)
          else
            cpio.add_directory(".#{item.dst}", item.mode, spec.mtime)
          end
        end
        cpio.close
        gzip.close
        {io.to_slice, cpio.written, digest.hexfinal}
      end

      # An IO that feeds a digest.
      private class DigestWriter < IO
        def initialize(@digest : Digest)
        end

        def read(slice : Bytes) : NoReturn
          raise IO::Error.new("write-only")
        end

        def write(slice : Bytes) : Nil
          @digest.update(slice)
        end
      end

      # rpm's file flags: RPMFILE_CONFIG is 1, RPMFILE_NOREPLACE 16.
      FILE_FLAGS = {
        PackageSpec::Kind::Regular         => 0,
        PackageSpec::Kind::Config          => 1,
        PackageSpec::Kind::ConfigNoreplace => 1 | 16,
      }

      # A file of the package (`src` set), a symbolic link (`link` set) or a
      # directory it owns (neither).
      private record Item, dst : String, src : String?, mode : Int32, flags : Int32 = 0, link : String? = nil do
        # A symbolic link's size is the length of its target, as rpmbuild
        # records it.
        def size : Int64
          link.try(&.bytesize.to_i64) || src.try { |path| File.size(path) } || 0_i64
        end

        # The full st_mode: file type bits, then the permissions.
        def file_mode : Int16
          type = link ? 0o120000 : (src ? 0o100000 : 0o040000)
          (type | mode).to_i16!
        end
      end

      # The files and the directories only this package creates, sorted by
      # path as rpm requires. Owning its directories is what lets `rpm -e`
      # remove them.
      private def self.items(spec : PackageSpec) : Array(Item)
        files = spec.files.map do |file|
          Item.new(file.dst, file.symlink? ? nil : file.src, file.mode, FILE_FLAGS[file.kind], file.link)
        end
        dirs = spec.owned_directories.map { |dir| Item.new(dir, nil, 0o755) }
        (files + dirs).sort_by!(&.dst)
      end

      # RPM headers store times as signed 32-bit seconds.
      def self.time32(time : Time) : Int32
        seconds = time.to_unix
        raise FormatError.new("an RPM package cannot hold a date after 2038-01-19") if seconds > Int32::MAX
        seconds.to_i32
      end

      # RPM headers store sizes on 32 bits.
      def self.int32(value : Int, what : String) : Int32
        raise FormatError.new("#{what} is too large for an RPM package (2 GiB limit)") if value > Int32::MAX
        value.to_i32
      end

      private def self.lead(spec : PackageSpec, arch : String) : Bytes
        io = IO::Memory.new
        io.write(LEAD_MAGIC)
        io.write_byte(3_u8)
        io.write_byte(0_u8)
        io.write_bytes(0_i16, IO::ByteFormat::BigEndian)
        io.write_bytes(LEAD_ARCHS[arch], IO::ByteFormat::BigEndian)
        name = "#{spec.name}-#{spec.package_version}-#{RELEASE}".byte_slice(0, 65)
        io.write(name.to_slice)
        io.write(Bytes.new(66 - name.bytesize))
        io.write_bytes(1_i16, IO::ByteFormat::BigEndian)
        io.write_bytes(5_i16, IO::ByteFormat::BigEndian)
        io.write(Bytes.new(16))
        io.to_slice
      end

      private def self.signature_entries(header : Bytes, payload : Bytes, payload_size : Int64,
                                         sign : Signer?) : Array(Entry)
        md5 = Digest::MD5.new
        md5.update(header)
        md5.update(payload)
        entries = [
          Entry.new(Tag::SIG_SHA1, Type::String, Digest::SHA1.hexdigest(header)),
          Entry.new(Tag::SIG_SHA256, Type::String, Digest::SHA256.hexdigest(header)),
          Entry.new(Tag::SIG_SIZE, Type::Int32, [int32(header.size.to_i64 + payload.size, "the package")]),
          Entry.new(Tag::SIG_MD5, Type::Bin, md5.final),
          Entry.new(Tag::SIG_PAYLOADSIZE, Type::Int32, [int32(payload_size, "the payload")]),
        ]
        if sign
          # What rpmsign signs for a header-only signature: the main header
          # from its magic on (rpm's sign/rpmgensig.cc, `sigt_v4`).
          packet = sign.call(header)
          entries << Entry.new(signature_tag(packet), Type::Bin, packet)
        end
        entries.sort_by!(&.tag)
      end

      private def self.main_entries(spec : PackageSpec, arch : String) : Array(Entry)
        files = items(spec)
        version = spec.package_version
        dirnames = files.map { |file| File.dirname(file.dst).rchop('/') + "/" }.uniq!
        requires = RPMLIB_REQUIRES.map { |(name, ver)| {name, ver, SENSE_RPMLIB | SENSE_LESS | SENSE_EQUAL} } +
                   spec.dependencies.map { |dependency| parse_dependency(dependency) }

        entries = [
          Entry.new(Tag::HEADERI18NTABLE, Type::StringArray, ["C"]),
          Entry.new(Tag::NAME, Type::String, spec.name),
          Entry.new(Tag::VERSION, Type::String, version),
          Entry.new(Tag::RELEASE, Type::String, RELEASE),
          Entry.new(Tag::SUMMARY, Type::I18nString, [spec.summary]),
          Entry.new(Tag::DESCRIPTION, Type::I18nString, [spec.description.strip.presence || spec.summary]),
          Entry.new(Tag::BUILDTIME, Type::Int32, [time32(spec.mtime)]),
          Entry.new(Tag::BUILDHOST, Type::String, "crystalreleaser"),
          # The sizes FILESIZES lists: rpmbuild counts a symbolic link by the
          # length of its target, where the deb's Installed-Size counts it
          # nothing.
          Entry.new(Tag::SIZE, Type::Int32, [int32(files.sum(0_i64, &.size), "the package content")]),
          Entry.new(Tag::LICENSE, Type::String, spec.license.presence || "Unknown"),
          Entry.new(Tag::PACKAGER, Type::String, spec.maintainer),
          Entry.new(Tag::GROUP, Type::I18nString, ["Unspecified"]),
          Entry.new(Tag::OS, Type::String, "linux"),
          Entry.new(Tag::ARCH, Type::String, arch),
          Entry.new(Tag::FILESIZES, Type::Int32, files.map { |file| int32(file.size, file.dst) }),
          Entry.new(Tag::FILEMODES, Type::Int16, files.map(&.file_mode)),
          Entry.new(Tag::FILERDEVS, Type::Int16, files.map { 0_i16 }),
          Entry.new(Tag::FILEMTIMES, Type::Int32, files.map { time32(spec.mtime) }),
          Entry.new(Tag::FILEDIGESTS, Type::StringArray, files.map { |file| file.src.try { |path| sha256_file(path) } || "" }),
          Entry.new(Tag::FILELINKTOS, Type::StringArray, files.map { |file| file.link || "" }),
          Entry.new(Tag::FILEFLAGS, Type::Int32, files.map(&.flags)),
          Entry.new(Tag::FILEUSERNAME, Type::StringArray, files.map { "root" }),
          Entry.new(Tag::FILEGROUPNAME, Type::StringArray, files.map { "root" }),
          # Its presence is what marks a binary (not source) package.
          Entry.new(Tag::SOURCERPM, Type::String, "#{spec.name}-#{version}-#{RELEASE}.src.rpm"),
          Entry.new(Tag::FILEVERIFYFLAGS, Type::Int32, files.map { -1 }),
          Entry.new(Tag::PROVIDENAME, Type::StringArray, [spec.name]),
          Entry.new(Tag::REQUIREFLAGS, Type::Int32, requires.map(&.[2])),
          Entry.new(Tag::REQUIRENAME, Type::StringArray, requires.map(&.[0])),
          Entry.new(Tag::REQUIREVERSION, Type::StringArray, requires.map(&.[1])),
          Entry.new(Tag::RPMVERSION, Type::String, "4.16.0"),
          Entry.new(Tag::FILEDEVICES, Type::Int32, files.map { 1 }),
          Entry.new(Tag::FILEINODES, Type::Int32, files.map_with_index { |_, index| index + 1 }),
          Entry.new(Tag::FILELANGS, Type::StringArray, files.map { "" }),
          Entry.new(Tag::PROVIDEFLAGS, Type::Int32, [SENSE_EQUAL]),
          Entry.new(Tag::PROVIDEVERSION, Type::StringArray, ["#{version}-#{RELEASE}"]),
          Entry.new(Tag::DIRINDEXES, Type::Int32, files.map { |file| dirnames.index!(File.dirname(file.dst).rchop('/') + "/") }),
          Entry.new(Tag::BASENAMES, Type::StringArray, files.map { |file| File.basename(file.dst) }),
          Entry.new(Tag::DIRNAMES, Type::StringArray, dirnames),
          Entry.new(Tag::PAYLOADFORMAT, Type::String, "cpio"),
          Entry.new(Tag::PAYLOADCOMPRESSOR, Type::String, "gzip"),
          Entry.new(Tag::PAYLOADFLAGS, Type::String, "9"),
          # 8 = SHA256, for FILEDIGESTS.
          Entry.new(Tag::FILEDIGESTALGO, Type::Int32, [8]),
        ]
        entries << Entry.new(Tag::VENDOR, Type::String, spec.vendor) unless spec.vendor.empty?
        entries << Entry.new(Tag::URL, Type::String, spec.homepage) unless spec.homepage.empty?
        entries.sort_by!(&.tag)
      end

      # {name, version, sense flags} of a dependency, in either spelling
      # PackageSpec.parse_dependency reads.
      def self.parse_dependency(text : String) : {String, String, Int32}
        name, operator, version = PackageSpec.parse_dependency(text)
        flags = {"" => 0, "<" => SENSE_LESS, "<=" => SENSE_LESS | SENSE_EQUAL, "=" => SENSE_EQUAL,
                 ">=" => SENSE_GREATER | SENSE_EQUAL, ">" => SENSE_GREATER}[operator]
        {name, version, flags}
      end

      private def self.sha256_file(path : String) : String
        digest = Digest::SHA256.new
        digest.file(path)
        digest.hexfinal
      end

      # A header structure: magic, index count, data size, index entries,
      # data store. Its first entry is the region tag whose 16-byte trailer
      # closes the data store, as rpm expects of an immutable header.
      def self.header(entries : Array(Entry), region_tag : Int32) : Bytes
        store = IO::Memory.new
        index = [] of {Int32, Int32, Int32, Int32}
        entries.each do |entry|
          align(store, entry.type)
          offset = store.pos.to_i32
          count = write_value(store, entry)
          index << {entry.tag, entry.type.value, offset, count}
        end

        count = entries.size + 1
        trailer_offset = store.pos.to_i32
        {region_tag, Type::Bin.value, -(count * 16), 16}.each { |field| store.write_bytes(field.to_i32, IO::ByteFormat::BigEndian) }
        index.unshift({region_tag, Type::Bin.value, trailer_offset, 16})

        io = IO::Memory.new
        io.write(HEADER_MAGIC)
        io.write_bytes(count.to_i32, IO::ByteFormat::BigEndian)
        io.write_bytes(store.size.to_i32, IO::ByteFormat::BigEndian)
        index.each { |entry| entry.each { |field| io.write_bytes(field, IO::ByteFormat::BigEndian) } }
        io.write(store.to_slice)
        io.to_slice
      end

      private def self.align(store : IO::Memory, type : Type) : Nil
        size = case type
               when .int16? then 2
               when .int32? then 4
               when .int64? then 8
               else              1
               end
        store.write(Bytes.new((size - store.pos % size) % size))
      end

      # Returns the entry count.
      private def self.write_value(store : IO::Memory, entry : Entry) : Int32
        case value = entry.value
        in String
          store << value << '\0'
          1
        in Array(String)
          value.each { |item| store << item << '\0' }
          value.size
        in Array(Int16)
          value.each { |item| store.write_bytes(item, IO::ByteFormat::BigEndian) }
          value.size
        in Array(Int32)
          value.each { |item| store.write_bytes(item, IO::ByteFormat::BigEndian) }
          value.size
        in Bytes
          store.write(value)
          value.size
        end
      end

      # Reads a header structure back (specs, and checks on generated
      # packages): tag => raw value, and the number of bytes it took.
      def self.read_header(io : IO) : {Hash(Int32, Value), Int32}
        magic = Bytes.new(8)
        io.read_fully(magic)
        raise FormatError.new("bad RPM header magic") unless magic == HEADER_MAGIC
        count = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        size = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        index = Array.new(count) { Array.new(4) { io.read_bytes(Int32, IO::ByteFormat::BigEndian) } }
        store = Bytes.new(size)
        io.read_fully(store)
        values = index.to_h do |(tag, type, offset, entries)|
          {tag, read_value(store, Type.new(type), offset, entries)}
        end
        {values, 16 + count * 16 + size}
      end

      private def self.read_value(store : Bytes, type : Type, offset : Int32, count : Int32) : Value
        data = IO::Memory.new(store)
        data.pos = offset
        case type
        when .string?
          data.gets('\0', chomp: true) || ""
        when .string_array?, .i18n_string?
          Array.new(count) { data.gets('\0', chomp: true) || "" }
        when .int16?
          Array.new(count) { data.read_bytes(Int16, IO::ByteFormat::BigEndian) }
        when .int32?
          Array.new(count) { data.read_bytes(Int32, IO::ByteFormat::BigEndian) }
        else
          # The region trailer's offset is negative by design; only the
          # signature digests are read as raw bytes.
          offset >= 0 ? store[offset, count] : Bytes.empty
        end
      end

      # Splits a package into lead, signature header, main header, the raw
      # main header bytes and the compressed payload.
      def self.read(io : IO) : {Bytes, Hash(Int32, Value), Hash(Int32, Value), Bytes, Bytes}
        lead = Bytes.new(96)
        io.read_fully(lead)
        signature, signature_size = read_header(io)
        io.skip((8 - signature_size % 8) % 8)
        rest = io.getb_to_end
        header, header_size = read_header(IO::Memory.new(rest))
        {lead, signature, header, rest[0, header_size], rest[header_size..]}
      end
    end
  end
end
