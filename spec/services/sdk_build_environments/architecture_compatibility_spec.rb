# frozen_string_literal: true

require "rails_helper"

RSpec.describe SdkBuildEnvironments::ArchitectureCompatibility, :no_db do
  describe ".normalize" do
    # @spec RUST-SDK-BUILD-001
    it "maps known aliases to OCI architecture names" do
      expect(described_class.normalize("x86_64")).to eq("amd64")
      expect(described_class.normalize("x64")).to eq("amd64")
      expect(described_class.normalize("amd64")).to eq("amd64")
      expect(described_class.normalize("aarch64")).to eq("arm64")
      expect(described_class.normalize("arm64")).to eq("arm64")
      expect(described_class.normalize("armv7l")).to eq("arm")
      expect(described_class.normalize("armhf")).to eq("arm")
    end

    # @spec RUST-SDK-BUILD-001
    it "returns nil for unrecognized values instead of guessing" do
      expect(described_class.normalize("riscv64")).to be_nil
      expect(described_class.normalize("")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe ".interpreter_architecture" do
    # @spec RUST-SDK-BUILD-002
    it "derives the architecture an ELF interpreter path implies" do
      expect(described_class.interpreter_architecture("/lib64/ld-linux-x86-64.so.2")).to eq("amd64")
      expect(described_class.interpreter_architecture("/lib/ld-linux-aarch64.so.1")).to eq("arm64")
      expect(described_class.interpreter_architecture("/lib/ld-linux-armhf.so.3")).to eq("arm")
      expect(described_class.interpreter_architecture("/lib/ld-linux.so.2")).to eq("386")
    end

    # @spec RUST-SDK-BUILD-002
    it "derives the architecture from Debian multiarch resolved loader paths" do
      path = "/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
      expect(described_class.interpreter_architecture(path)).to eq("arm64")

      path = "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
      expect(described_class.interpreter_architecture(path)).to eq("amd64")
    end

    # @spec RUST-SDK-BUILD-002
    it "returns nil for a path implying no known architecture" do
      expect(described_class.interpreter_architecture("/lib/ld-custom-loader.so")).to be_nil
      expect(described_class.interpreter_architecture("")).to be_nil
      expect(described_class.interpreter_architecture(nil)).to be_nil
    end
  end

  describe ".classify_toolchain" do
    # @spec RUST-SDK-BUILD-003
    it "classifies matching interpreter and process architectures as compatible" do
      result = described_class.classify_toolchain(
        process_architecture: "aarch64",
        interpreter_path: "/lib/ld-linux-aarch64.so.1"
      )

      expect(result[:status]).to be(:compatible)
      expect(result[:process_architecture]).to eq("arm64")
      expect(result[:binary_architecture]).to eq("arm64")
    end

    # @spec RUST-SDK-BUILD-003
    it "classifies a mismatch naming both the binary and the runner architecture" do
      result = described_class.classify_toolchain(
        process_architecture: "aarch64",
        interpreter_path: "/lib64/ld-linux-x86-64.so.2"
      )

      expect(result[:status]).to be(:architecture_mismatch)
      expect(result[:binary_architecture]).to eq("amd64")
      expect(result[:process_architecture]).to eq("arm64")
      expect(result[:detail]).to include("amd64").and include("arm64")
    end

    it "honors an explicit binary architecture over the interpreter path" do
      result = described_class.classify_toolchain(
        process_architecture: "arm64",
        binary_architecture: "aarch64",
        interpreter_path: "/lib64/ld-linux-x86-64.so.2"
      )

      expect(result[:status]).to be(:compatible)
    end

    it "classifies observations it cannot resolve as unknown" do
      expect(
        described_class.classify_toolchain(process_architecture: nil, interpreter_path: nil)[:status]
      ).to be(:unknown)
      expect(
        described_class.classify_toolchain(process_architecture: "aarch64", interpreter_path: nil)[:status]
      ).to be(:unknown)
      expect(
        described_class.classify_toolchain(process_architecture: "aarch64", interpreter_path: "/lib/ld-custom.so")[:status]
      ).to be(:unknown)
    end
  end

  describe ".classify_loader_failure" do
    # @spec RUST-SDK-BUILD-004
    it "classifies a loader mismatch against a known process architecture" do
      output = "OrbStack ERROR: Dynamic loader not found: /lib64/ld-linux-x86-64.so.2"

      result = described_class.classify_loader_failure(output, process_architecture: "aarch64")

      expect(result[:kind]).to eq("foreign_architecture_binary")
      expect(result[:loader_path]).to eq("/lib64/ld-linux-x86-64.so.2")
      expect(result[:loader_architecture]).to eq("amd64")
      expect(result[:process_architecture]).to eq("arm64")
      expect(result[:detail]).to include("amd64").and include("arm64")
    end

    [ nil, "unknown" ].each do |process|
      it "does not claim compatibility when the process architecture is #{process.inspect}" do # @spec RUST-SDK-BUILD-004
        result = described_class.classify_loader_failure(
          "Dynamic loader not found: /lib64/ld-linux-x86-64.so.2", process_architecture: process
        )

        expect(result[:kind]).to eq("unknown_process_architecture")
        expect(result[:loader_architecture]).to eq("amd64")
        expect(result[:process_architecture]).to be_nil
      end
    end

    # @spec RUST-SDK-BUILD-004
    it "returns no classification when the output carries no loader failure signature" do
      expect(described_class.classify_loader_failure("cargo 1.88.0")).to be_nil
      expect(described_class.classify_loader_failure("")).to be_nil
      expect(described_class.classify_loader_failure(nil)).to be_nil
    end

    it "does not misattribute a matching loader to a foreign architecture" do
      output = "Dynamic loader not found: /lib/ld-linux-aarch64.so.1"

      result = described_class.classify_loader_failure(output, process_architecture: "aarch64")

      expect(result[:kind]).to eq("missing_compatible_loader")
      expect(result[:loader_architecture]).to eq("arm64")
      expect(result[:process_architecture]).to eq("arm64")
    end
  end
end
