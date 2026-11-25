# frozen_string_literal: true

require "rails_helper"

RSpec.describe SdkBuildEnvironments::Preflight, :no_db do
  def facts(overrides = {})
    {
      backend_identifier: "local",
      engine_architecture: "aarch64",
      image: {
        reference: "rust@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1",
        id: "sha256:7cf1e580ef5539f03b58560753e8ab84c8c360960d99dff714004aa98f203977",
        digest: "sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1",
        platform: "arm64"
      },
      process_architecture: "aarch64",
      toolchains: [
        { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: "/lib/ld-linux-aarch64.so.1", execution_status: 0 },
        { command: "rustc", path: "/usr/local/rustup/toolchains/bin/rustc", interpreter_path: "/lib/ld-linux-aarch64.so.1", execution_status: 0 }
      ]
    }.merge(overrides)
  end

  describe ".call" do
    # @spec RUST-SDK-BUILD-008
    it "records the environment identity in the receipt" do
      receipt = described_class.call(facts: facts)

      expect(receipt[:backend]).to eq("local")
      expect(receipt[:engine_architecture]).to eq("arm64")
      expect(receipt[:image]).to include(reference: "rust@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1",
        platform: "arm64")
      expect(receipt[:process_architecture]).to eq("arm64")
      expect(receipt[:toolchains]).to all(include(:command, :path, :interpreter_path, :architecture))
    end

    # @spec RUST-SDK-BUILD-008
    it "contains no credential material" do
      receipt = described_class.call(facts: facts)

      expect(receipt.to_s).not_to match(/token|secret|password|api[-_]?key/i)
    end

    it "returns a compatible verdict for a matching environment" do
      receipt = described_class.call(facts: facts)

      expect(receipt[:verdict]).to be(:compatible)
      expect(receipt[:remediation_hint]).to be_nil
      expect(receipt[:checks]).to all(include(healthy: true))
    end

    # @spec RUST-SDK-BUILD-010
    it "records an absent optional rustup observation without failing preflight" do
      rustup = { command: "rustup", path: nil, interpreter_path: nil, execution_status: nil }

      receipt = described_class.call(facts: facts(toolchains: [ *facts[:toolchains], rustup ]))

      expect(receipt[:verdict]).to be(:compatible)
      expect(receipt[:toolchains]).to include(hash_including(command: "rustup", path: nil))
      expect(receipt[:checks]).not_to include(hash_including(name: "toolchain_presence:rustup"))
      expect(receipt[:checks]).not_to include(hash_including(name: "toolchain_loader:rustup"))
    end

    # @spec RUST-SDK-BUILD-010
    it "fails when a required toolchain command cannot run" do
      toolchains = facts[:toolchains].map do |toolchain|
        toolchain.merge(execution_status: toolchain[:command] == "cargo" ? 127 : 0)
      end

      receipt = described_class.call(facts: facts(toolchains: toolchains))

      expect(receipt[:verdict]).to be(:toolchain_unusable)
      expect(receipt[:remediation_hint]).to include("cargo")
      expect(receipt[:checks]).to include(hash_including(name: "toolchain_execution:cargo", healthy: false))
    end

    # @spec RUST-SDK-BUILD-009
    it "fails with image_architecture_mismatch when engine and image architectures disagree" do
      image = facts[:image].merge(platform: "amd64")

      receipt = described_class.call(facts: facts(image: image))

      expect(receipt[:verdict]).to be(:image_architecture_mismatch)
      expect(receipt[:remediation_hint]).to include("arm64")
      expect(receipt[:checks]).to include(hash_including(name: "image_architecture", healthy: false))
    end

    # @spec RUST-SDK-BUILD-009
    it "fails with unverifiable_image_architecture when the image platform is absent" do
      image = facts[:image].merge(platform: nil)

      receipt = described_class.call(facts: facts(image: image))

      expect(receipt[:verdict]).to be(:unverifiable_image_architecture)
      expect(receipt[:checks]).to include(hash_including(name: "image_architecture", healthy: false))
    end

    # @spec RUST-SDK-BUILD-010
    it "fails with toolchain_absent when a toolchain is missing from the environment PATH" do
      toolchains = [
        { command: "cargo", path: nil, interpreter_path: nil },
        { command: "rustc", path: "/usr/local/rustup/toolchains/bin/rustc", interpreter_path: "/lib/ld-linux-aarch64.so.1" }
      ]

      receipt = described_class.call(facts: facts(toolchains: toolchains))

      expect(receipt[:verdict]).to be(:toolchain_absent)
      expect(receipt[:remediation_hint]).to include("cargo")
      expect(receipt[:checks]).to include(hash_including(name: "toolchain_presence:cargo", healthy: false))
    end

    # @spec RUST-SDK-BUILD-010
    it "fails with loader_architecture_mismatch when the interpreter targets a foreign architecture" do
      toolchains = [
        { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: "/lib64/ld-linux-x86-64.so.2" }
      ]

      receipt = described_class.call(facts: facts(toolchains: toolchains))

      expect(receipt[:verdict]).to be(:loader_architecture_mismatch)
      expect(receipt[:remediation_hint]).to include("amd64").and include("arm64")
      expect(receipt[:checks]).to include(hash_including(name: "toolchain_loader:cargo", healthy: false))
    end

    it "fails with unverifiable when the engine architecture cannot be normalized" do
      receipt = described_class.call(facts: facts(engine_architecture: nil))

      expect(receipt[:verdict]).to be(:unverifiable)
    end

    # @spec RUST-SDK-BUILD-009
    it "fails when the observed process identity disagrees with the engine and image" do
      toolchains = [
        { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: "/lib64/ld-linux-x86-64.so.2" },
        { command: "rustc", path: "/usr/local/rustup/toolchains/bin/rustc", interpreter_path: "/lib64/ld-linux-x86-64.so.2" }
      ]

      receipt = described_class.call(facts: facts(process_architecture: "x86_64", toolchains: toolchains))

      expect(receipt[:verdict]).to be(:process_architecture_mismatch)
      expect(receipt[:checks]).to include(hash_including(name: "process_architecture", healthy: false))
    end

    # @spec RUST-SDK-BUILD-010
    it "fails when the metadata probe did not complete" do
      receipt = described_class.call(facts: facts(toolchains: [], probe_error: "Docker::Error::TimeoutError: deadline exceeded"))

      expect(receipt[:verdict]).to be(:unverifiable)
      expect(receipt[:checks]).to include(hash_including(name: "probe", healthy: false))
    end

    # @spec RUST-SDK-BUILD-010
    it "requires cargo and rustc even when the probe reports an empty inventory" do
      receipt = described_class.call(facts: facts(toolchains: []))

      expect(receipt[:verdict]).to be(:toolchain_absent)
      expect(receipt[:checks]).to include(
        hash_including(name: "toolchain_presence:cargo", healthy: false),
        hash_including(name: "toolchain_presence:rustc", healthy: false)
      )
    end

    it "fails with unverifiable when a toolchain interpreter cannot be resolved" do
      toolchains = [ { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: nil } ]

      receipt = described_class.call(facts: facts(toolchains: toolchains))

      expect(receipt[:verdict]).to be(:unverifiable)
      expect(receipt[:checks]).to include(hash_including(name: "toolchain_loader:cargo", healthy: false))
    end
  end
end
