# frozen_string_literal: true

module SdkBuildEnvironments
  # Frozen registry of the architecture-compatible Rust/SDK build recipe,
  # verified against exact sources on 2026-11-24 (evidence: the root probe
  # receipts referenced in issue #5358 — official linux/arm64 toolchain
  # images pulled by immutable digest, checksum-verified protoc and
  # libclang artifacts, and the exact Ruby SDK / Core / Cargo.lock source
  # identities). Job-scoped build input for #5326's harness: deliberately
  # NOT part of the `bin/update` pin registry or the agent image — see
  # docs/intent/isolated-rust-sdk-build/isolated-rust-sdk-build-design.md.
  #
  # @spec RUST-SDK-BUILD-005
  # @spec RUST-SDK-BUILD-006
  # @spec RUST-SDK-BUILD-007
  class Pins
    class UnsupportedArchitectureError < StandardError; end
    class PinFormatError < StandardError; end

    DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/.freeze
    BARE_SHA256_FORMAT = /\A[0-9a-f]{64}\z/.freeze
    GIT_SHA_FORMAT = /\A[0-9a-f]{40}\z/.freeze

    # The Core development toolchain pin (checked-in rust-toolchain.toml,
    # 1.95.0) is distinct from the crate MSRV floor (1.88.0): only 1.95
    # compiled the exact locked source. Both images are recorded so
    # callers can state which pin their evidence used.
    TOOLCHAIN_IMAGES = {
      "arm64" => {
        "development" => {
          role: "development",
          reference: "rust:1.95.0-bookworm",
          repo_digest: "sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1",
          image_id: "sha256:7cf1e580ef5539f03b58560753e8ab84c8c360960d99dff714004aa98f203977",
          rust_version: "1.95.0"
        },
        "msrv_floor" => {
          role: "msrv_floor",
          reference: "rust:1.88.0-bookworm",
          repo_digest: "sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0",
          image_id: "sha256:9ad0c47880881464036f8b5779f49a15d058154581404d0d50a20f9d11f3436e",
          rust_version: "1.88.0"
        }
      }.freeze
    }.freeze

    PROTOC = {
      version: "34.0",
      assets: {
        "arm64" => {
          asset: "protoc-34.0-linux-aarch_64.zip",
          sha256: "f0b8aad28be5ea6150c082f96ac57e028154afb9ee29f4ce092b5a39df8ae6c8"
        }
      }.freeze
    }.freeze

    LIBCLANG = {
      "arm64" => {
        package_version: "1:18.1.3-1ubuntu1",
        packages: %w[libclang-18-dev libclang-common-18-dev libclang1-18 libllvm18].freeze,
        library_path: "/usr/lib/llvm-18/lib/libclang.so.1",
        library_sha256: "be2902f406fd2f64bd665e0675620b4fabfdaa3fabddb1553ef531c80d3cb0a4"
      }.freeze
    }.freeze

    SOURCE = {
      ruby_sdk: {
        repository: "temporalio/sdk-ruby",
        version: "v1.11.0",
        commit: "61db6dd4b75e3b15731e58f26934b33c17663237"
      }.freeze,
      core: {
        repository: "temporalio/sdk-rust",
        path: "ext/sdk-core gitlink",
        commit: "c675c32469af707e1c979a7b808c70b4a0608b82"
      }.freeze,
      cargo_lock_sha256: "47aba453a6f46d71b5deba2d09e1e6b9ef036cc5ba7263562793205e142bc9aa"
    }.freeze

    # A build for the agent image's static Ruby is not interchangeable
    # with a shared-Ruby host build (extension ABI differs), so every
    # load claim must name the profile it proves.
    RUBY_BUILD_PROFILE = {
      version: "3.4.13",
      extension_api_version: "3.4.0",
      linkage: "static",
      enable_shared: false
    }.freeze

    class << self
      def supported_architectures
        TOOLCHAIN_IMAGES.keys.freeze
      end

      # @spec RUST-SDK-BUILD-006
      def for_architecture(value)
        architecture = ArchitectureCompatibility.normalize(value)
        unless supported_architectures.include?(architecture)
          raise UnsupportedArchitectureError,
            "no pinned SDK build recipe for #{value.inspect}; supported architectures: #{supported_architectures.join(', ')}"
        end

        images = TOOLCHAIN_IMAGES.fetch(architecture)
        asset = PROTOC.fetch(:assets).fetch(architecture)
        {
          architecture: architecture,
          toolchain_image: images.fetch("development"),
          msrv_floor_image: images.fetch("msrv_floor"),
          protoc: { version: PROTOC.fetch(:version) }.merge(asset),
          libclang: LIBCLANG.fetch(architecture),
          source: SOURCE,
          ruby_build_profile: RUBY_BUILD_PROFILE
        }
      end

      # The digest-pinned development toolchain reference used as the
      # default preflight image: an immutable identity, unlike the mutable
      # tag that made the #5358 historical failure undiagnosable.
      def default_image_reference
        image = TOOLCHAIN_IMAGES.fetch("arm64").fetch("development")
        "#{image.fetch(:reference).split(":", 2).first}@#{image.fetch(:repo_digest)}"
      end

      # @spec RUST-SDK-BUILD-005
      def validate_format!
        violations = format_violations
        raise PinFormatError, "invalid SDK build pins: #{violations.join('; ')}" if violations.any?

        true
      end

      private

      def format_violations
        [].tap do |violations|
          collect_image_violations(violations)
          supported_architectures.each do |architecture|
            collect_recipe_violations(violations, for_architecture(architecture))
          end
        end
      end

      def collect_image_violations(violations)
        TOOLCHAIN_IMAGES.each_value do |roles|
          roles.each_value do |image|
            violations << "#{image[:reference]} repo_digest" unless image[:repo_digest].match?(DIGEST_FORMAT)
            violations << "#{image[:reference]} image_id" unless image[:image_id].match?(DIGEST_FORMAT)
          end
        end
      end

      def collect_recipe_violations(violations, recipe)
        violations << "protoc sha256" unless recipe[:protoc][:sha256].match?(BARE_SHA256_FORMAT)
        violations << "libclang library_sha256" unless recipe[:libclang][:library_sha256].match?(BARE_SHA256_FORMAT)
        violations << "ruby_sdk commit" unless recipe[:source][:ruby_sdk][:commit].match?(GIT_SHA_FORMAT)
        violations << "core commit" unless recipe[:source][:core][:commit].match?(GIT_SHA_FORMAT)
        violations << "cargo_lock sha256" unless recipe[:source][:cargo_lock_sha256].match?(BARE_SHA256_FORMAT)
      end
    end
  end
end
