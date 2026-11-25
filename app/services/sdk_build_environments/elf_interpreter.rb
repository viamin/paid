# frozen_string_literal: true

module SdkBuildEnvironments
  # Minimal pure-Ruby ELF program-header reader for PT_INTERP, so preflight
  # can derive a toolchain binary's loader mapping from its leading bytes
  # without depending on readelf or file inside the probed image. Handles
  # ELF32 and ELF64, either endianness; anything malformed yields nil so
  # callers classify the observation as unverifiable rather than crashing
  # on untrusted file input.
  class ElfInterpreter
    ELF_MAGIC = "\x7fELF".b.freeze
    PT_INTERP = 3
    MAX_PROGRAM_HEADERS = 65_536
    MAX_INTERP_BYTES = 4096

    ENDIAN_FOR_DATA = { 1 => "<", 2 => ">" }.freeze
    # v/V are little-endian, n/N big-endian; Q takes an explicit < or >.
    HEADER_FORMATS = {
      [ 1, "<" ] => "x16vvVVVVVvvvvvv",
      [ 1, ">" ] => "x16nnNNNNNnnnnnn",
      [ 2, "<" ] => "x16vvVQ<Q<Q<Vvvvvvv",
      [ 2, ">" ] => "x16nnNQ>Q>Q>Nnnnnnn"
    }.freeze
    PHDR_FORMATS = {
      [ 1, "<" ] => "VVVVVVVV",
      [ 1, ">" ] => "NNNNNNNN",
      [ 2, "<" ] => "VVQ<Q<Q<Q<Q<Q<",
      [ 2, ">" ] => "NNQ>Q>Q>Q>Q>Q>"
    }.freeze
    # Field positions shared by both ELF classes after the 16-byte e_ident.
    PHOFF_INDEX = 4
    PHENTSIZE_INDEX = 8
    PHNUM_INDEX = 9

    class << self
      # @param bytes [String, nil] leading bytes of a candidate ELF binary
      # @return [String, nil] the PT_INTERP path, or nil when absent,
      #   truncated, or not an ELF binary
      def for_bytes(bytes)
        string = bytes.to_s.b
        return nil if string.bytesize < 52
        return nil unless string.byteslice(0, 4) == ELF_MAGIC

        endian = ENDIAN_FOR_DATA.fetch(string.getbyte(5), nil)
        return nil unless endian

        elf_class = string.getbyte(4)
        header_format = HEADER_FORMATS[[ elf_class, endian ]]
        return nil unless header_format

        interpret(string, endian:, elf_class:, fields: string.unpack(header_format))
      end

      private

      def interpret(string, endian:, elf_class:, fields:)
        phoff = fields[PHOFF_INDEX]
        phentsize = fields[PHENTSIZE_INDEX]
        phnum = fields[PHNUM_INDEX]
        return nil if phoff.nil? || phentsize.nil? || phnum.nil?
        return nil if phentsize < 32 || phnum.zero? || phnum > MAX_PROGRAM_HEADERS

        offset_index, filesz_index = elf_class == 2 ? [ 2, 5 ] : [ 1, 4 ]
        phdr_format = PHDR_FORMATS.fetch([ elf_class, endian ])
        phnum.times do |index|
          entry = string.byteslice(phoff + index * phentsize, phentsize)
          return nil if entry.nil?

          values = entry.unpack(phdr_format)
          next unless values.first == PT_INTERP

          return interp_string(string, values[offset_index], values[filesz_index])
        end
        nil
      end

      def interp_string(string, offset, filesz)
        return nil if filesz.nil? || filesz <= 1 || filesz > MAX_INTERP_BYTES

        raw = string.byteslice(offset, filesz)
        return nil if raw.nil?

        path = raw.unpack1("Z*").to_s
        return nil if path.empty?

        path.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
