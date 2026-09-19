# frozen_string_literal: true

# Provider-neutral contracts for Apple verification workers. Provider adapters
# translate these values; manifests never carry host paths, provider lifecycle
# fields, or credential values.
# @spec APPLE-WORKER-001
# @spec APPLE-WORKER-002
module AppleVerificationWorkers
  MANIFEST_SCHEMA_VERSION = "remote_execution.apple_verification.v1"
  CAPABILITIES = %i[build test launch ui_flow screenshot].freeze
  PLATFORMS = %w[ios ipados macos].freeze
  FORBIDDEN_KEYS = %w[
    host_path host_paths mount mounts command shell provider provider_handle
    lifecycle vm_id credential token secret password
  ].freeze

  class UnsupportedCapability < StandardError; end
  class InvalidManifest < StandardError; end

  ProfileConstraints = Data.define(:platforms, :xcode_version, :simulator_runtimes, :capabilities) do
    def initialize(platforms:, xcode_version:, simulator_runtimes: [], capabilities: [])
      super(
        platforms: Array(platforms).map(&:to_s).uniq,
        xcode_version: xcode_version.to_s,
        simulator_runtimes: Array(simulator_runtimes).map(&:to_s).uniq,
        capabilities: normalize_capabilities(capabilities)
      )
      raise UnsupportedCapability, "unsupported Apple platform" unless (self.platforms - PLATFORMS).empty?
      raise ArgumentError, "xcode version constraint is required" if self.xcode_version.blank?
    end

    def supports?(platform:, required_capabilities:)
      platforms.include?(platform.to_s) && (normalize_capabilities(required_capabilities) - capabilities).empty?
    end

    private

    def normalize_capabilities(values)
      normalized = Array(values).map(&:to_sym).uniq
      unknown = normalized - CAPABILITIES
      raise UnsupportedCapability, "unsupported Apple worker capabilities: #{unknown.join(', ')}" if unknown.any?

      normalized.freeze
    end
  end

  InputManifest = Data.define(:schema_version, :source, :verification, :profile, :lanes) do
    def initialize(schema_version: MANIFEST_SCHEMA_VERSION, source:, verification:, profile:, lanes:)
      super(schema_version:, source:, verification:, profile:, lanes:)
      AppleVerificationWorkers.validate_manifest!(as_json)
    end

    def as_json(*)
      { "schema_version" => schema_version, "source" => source, "verification" => verification, "profile" => profile, "lanes" => lanes }
    end
  end

  OutputManifest = Data.define(:schema_version, :attempt, :result, :artifacts, :lanes) do
    def initialize(schema_version: MANIFEST_SCHEMA_VERSION, attempt:, result:, artifacts:, lanes:)
      super(schema_version:, attempt:, result:, artifacts:, lanes:)
      AppleVerificationWorkers.validate_manifest!(as_json)
    end

    def as_json(*)
      { "schema_version" => schema_version, "attempt" => attempt, "result" => result, "artifacts" => artifacts, "lanes" => lanes }
    end
  end

  def self.validate_manifest!(manifest)
    validate_object!(manifest)
    validate_no_forbidden_keys!(manifest)
    validate_lanes!(manifest.fetch("lanes"))
  end

  def self.validate_object!(value)
    raise InvalidManifest, "manifest must be an object" unless value.is_a?(Hash)
  end

  def self.validate_no_forbidden_keys!(value)
    case value
    when Hash
      value.each do |key, nested|
        raise InvalidManifest, "manifest contains forbidden field #{key}" if FORBIDDEN_KEYS.include?(key.to_s)

        validate_no_forbidden_keys!(nested)
      end
    when Array
      value.each { |nested| validate_no_forbidden_keys!(nested) }
    end
  end

  def self.validate_lanes!(lanes)
    raise InvalidManifest, "manifest lanes must be an object" unless lanes.is_a?(Hash)
    raise InvalidManifest, "credential lane must contain references only" if Array(lanes["credentials"]).any? { |entry| !credential_reference?(entry) }
  end

  def self.credential_reference?(entry)
    entry.is_a?(Hash) && entry["lane"] == "credentials" && entry["kind"].present? && entry["locator"].is_a?(Hash) && entry.keys.all? { |key| %w[lane kind locator].include?(key.to_s) }
  end
end
