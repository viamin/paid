# frozen_string_literal: true

require "rails_helper"

RSpec.describe SdkBuildEnvironments::ElfInterpreter, :no_db do
  def elf64_header(program_header_offset:, program_header_count:, machine: 183)
    [
      "\x7fELF".b, [ 2, 1, 1, 0 ].pack("C4"), "\x00" * 8,
      [ 2, machine, 1, 0, program_header_offset, 0, 0, 64, 56, program_header_count, 0, 0, 0 ]
        .pack("vvVQ<Q<Q<Vvvvvvv")
    ].join.b
  end

  def interp_header64(offset:, size:)
    [ 3, 4, offset, offset, offset, size, size, 1 ].pack("VVQ<Q<Q<Q<Q<Q<")
  end

  def elf64_with_interpreter(interpreter, machine: 183)
    interpreter = interpreter.b
    header_offset = 64 + 56
    elf64_header(program_header_offset: 64, program_header_count: 1, machine: machine) +
      interp_header64(offset: header_offset, size: interpreter.bytesize + 1) +
      interpreter + "\x00".b
  end

  describe ".for_bytes" do
    it "reads the PT_INTERP path from an ELF64 binary" do
      binary = elf64_with_interpreter("/lib64/ld-linux-x86-64.so.2", machine: 62)

      expect(described_class.for_bytes(binary)).to eq("/lib64/ld-linux-x86-64.so.2")
    end

    it "reads the PT_INTERP path from an aarch64 ELF64 binary" do
      binary = elf64_with_interpreter("/lib/ld-linux-aarch64.so.1")

      expect(described_class.for_bytes(binary)).to eq("/lib/ld-linux-aarch64.so.1")
    end

    it "returns nil for a binary with no PT_INTERP segment" do
      binary = elf64_header(program_header_offset: 0, program_header_count: 0)

      expect(described_class.for_bytes(binary)).to be_nil
    end

    it "returns nil for input that is not an ELF binary" do
      expect(described_class.for_bytes("#!/bin/sh\n")).to be_nil
      expect(described_class.for_bytes("")).to be_nil
      expect(described_class.for_bytes(nil)).to be_nil
    end

    it "returns nil for a truncated header rather than raising" do
      binary = elf64_with_interpreter("/lib/ld-linux-aarch64.so.1")

      expect(described_class.for_bytes(binary[0, 20])).to be_nil
      expect(described_class.for_bytes(binary[0, 70])).to be_nil
    end
  end
end
