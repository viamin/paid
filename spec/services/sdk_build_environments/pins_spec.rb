# frozen_string_literal: true

require "rails_helper"

RSpec.describe SdkBuildEnvironments::Pins, :no_db do
  let(:sha256_format) { %r{\Asha256:[0-9a-f]{64}\z} }
  let(:bare_sha256_format) { /\A[0-9a-f]{64}\z/ }

  describe ".for_architecture" do
    # @spec RUST-SDK-BUILD-006
    it "returns the complete pin set for a supported architecture" do
      recipe = described_class.for_architecture("aarch64")

      expect(recipe[:architecture]).to eq("arm64")
      expect(recipe[:toolchain_image]).to include(:reference, :repo_digest, :image_id, :rust_version)
      expect(recipe[:protoc]).to include(:version, :asset, :sha256)
      expect(recipe[:libclang]).to include(:package_version, :packages, :library_path, :library_sha256)
      expect(recipe[:source]).to include(:ruby_sdk, :core, :cargo_lock_sha256)
      expect(recipe[:ruby_build_profile]).to include(:version, :extension_api_version, :linkage, :enable_shared)
    end

    it "normalizes aliases to the supported architecture" do
      expect(described_class.for_architecture("arm64")[:toolchain_image][:rust_version]).to eq(
        described_class.for_architecture("aarch64")[:toolchain_image][:rust_version]
      )
    end

    # @spec RUST-SDK-BUILD-006
    it "raises a named error naming the supported set for an unsupported architecture" do
      expect { described_class.for_architecture("amd64") }
        .to raise_error(SdkBuildEnvironments::Pins::UnsupportedArchitectureError, /arm64/)
    end
  end

  describe "pin integrity" do
    let(:recipe) { described_class.for_architecture("arm64") }

    # @spec RUST-SDK-BUILD-005
    it "carries immutable digests for every toolchain image reference" do
      [ recipe[:toolchain_image], described_class.for_architecture("arm64")[:msrv_floor_image] ].each do |image|
        expect(image[:reference]).to be_present
        expect(image[:repo_digest]).to match(sha256_format)
        expect(image[:image_id]).to match(sha256_format)
      end
    end

    # @spec RUST-SDK-BUILD-005
    it "carries a SHA-256 checksum for every checksummed artifact" do
      expect(recipe[:protoc][:sha256]).to match(bare_sha256_format)
      expect(recipe[:libclang][:library_sha256]).to match(bare_sha256_format)
    end

    # @spec RUST-SDK-BUILD-005
    it "carries full-length hex SHAs for every source pin" do
      git_sha_format = /\A[0-9a-f]{40}\z/.freeze

      expect(recipe[:source][:ruby_sdk][:commit]).to match(git_sha_format)
      expect(recipe[:source][:core][:commit]).to match(git_sha_format)
      expect(recipe[:source][:cargo_lock_sha256]).to match(bare_sha256_format)
    end

    # @spec RUST-SDK-BUILD-005
    it "identifies the Ruby SDK's actual Core gitlink workspace" do
      expect(recipe[:source][:core][:path]).to eq("temporalio/ext/sdk-core")
    end

    # @spec RUST-SDK-BUILD-007
    it "distinguishes the Core development toolchain pin from the MSRV floor" do
      expect(recipe[:toolchain_image][:rust_version]).to eq("1.95.0")
      expect(recipe[:msrv_floor_image][:rust_version]).to eq("1.88.0")
      expect(recipe[:msrv_floor_image][:role]).to eq("msrv_floor")
      expect(recipe[:toolchain_image][:role]).to eq("development")
    end

    # @spec RUST-SDK-BUILD-007
    it "records the target Ruby build profile" do
      profile = recipe[:ruby_build_profile]

      expect(profile[:version]).to eq("3.4.13")
      expect(profile[:extension_api_version]).to eq("3.4.0")
      expect(profile[:linkage]).to eq("static")
      expect(profile[:enable_shared]).to be(false)
    end
  end

  describe ".validate_format!" do
    # @spec RUST-SDK-BUILD-005
    it "passes on the shipped recipe" do
      expect { described_class.validate_format! }.not_to raise_error
    end
  end

  describe ".default_image_reference" do
    it "resolves to the digest-pinned development toolchain image" do
      expect(described_class.default_image_reference)
        .to eq("rust@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1")
    end
  end
end
