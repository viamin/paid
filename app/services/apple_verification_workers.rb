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
  FORBIDDEN_KEYS = (
    %w[
      host_path host_paths mount mounts command shell provider provider_handle
      lifecycle vm_id credential token secret password
    ] + SecretSafeMetadata::FORBIDDEN_METADATA_KEYS
  ).uniq.freeze
  INPUT_MANIFEST_FIELDS = %w[schema_version source verification profile lanes].freeze
  OUTPUT_MANIFEST_FIELDS = %w[schema_version attempt result artifacts lanes].freeze
  LANE_NAMES = %w[git control_plane_api object_storage credentials].freeze
  INPUT_SECTION_FIELDS = {
    "source" => %w[digest commit_sha bundle_digest],
    "verification" => %w[operations workflow_digest],
    "profile" => %w[digest platform xcode_version]
  }.freeze
  OUTPUT_SECTION_FIELDS = {
    "attempt" => %w[id source_digest workflow_revision lifecycle_gate profile_digest],
    "result" => %w[status timings retry_lineage failure_classification required_checks advisory_checks screenshot_metadata network_policy audit_event_references ledger_entry_references],
    "artifacts" => %w[xcresult build_logs screenshots diagnostics references]
  }.freeze

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
      AppleVerificationWorkers.validate_input_manifest!(as_json)
    end

    def as_json(*)
      { "schema_version" => schema_version, "source" => source, "verification" => verification, "profile" => profile, "lanes" => lanes }
    end
  end

  OutputManifest = Data.define(:schema_version, :attempt, :result, :artifacts, :lanes) do
    def initialize(schema_version: MANIFEST_SCHEMA_VERSION, attempt:, result:, artifacts:, lanes:)
      super(schema_version:, attempt:, result:, artifacts:, lanes:)
      AppleVerificationWorkers.validate_output_manifest!(as_json)
    end

    def as_json(*)
      { "schema_version" => schema_version, "attempt" => attempt, "result" => result, "artifacts" => artifacts, "lanes" => lanes }
    end
  end

  def self.validate_input_manifest!(manifest)
    validate_manifest!(manifest, allowed_fields: INPUT_MANIFEST_FIELDS, section_fields: INPUT_SECTION_FIELDS)
  end

  def self.validate_output_manifest!(manifest)
    validate_manifest!(manifest, allowed_fields: OUTPUT_MANIFEST_FIELDS, section_fields: OUTPUT_SECTION_FIELDS)
  end

  def self.validate_manifest!(manifest, allowed_fields:, section_fields:)
    validate_object!(manifest)
    validate_allowed_fields!(manifest, allowed_fields, "manifest")
    validate_section_fields!(manifest, section_fields)
    validate_no_forbidden_keys!(manifest.except("lanes"))
    validate_no_secret_shaped_values!(manifest)
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

  def self.validate_allowed_fields!(value, allowed_fields, context)
    unknown_fields = value.keys.map(&:to_s) - allowed_fields
    return if unknown_fields.empty?

    raise InvalidManifest, "#{context} contains unknown field #{unknown_fields.first}"
  end

  def self.validate_section_fields!(manifest, section_fields)
    section_fields.each do |section, allowed_fields|
      validate_object!(manifest.fetch(section))
      validate_allowed_fields!(manifest.fetch(section), allowed_fields, "manifest #{section}")
    end
  end

  def self.validate_no_secret_shaped_values!(value)
    case value
    when Hash
      value.each_value { |nested| validate_no_secret_shaped_values!(nested) }
    when Array
      value.each { |nested| validate_no_secret_shaped_values!(nested) }
    when String
      raise InvalidManifest, "manifest contains a secret-shaped value" if SecretSafeMetadata.secret_like?(value)
    end
  end

  def self.validate_lanes!(lanes)
    raise InvalidManifest, "manifest lanes must be an object" unless lanes.is_a?(Hash)
    validate_allowed_fields!(lanes, LANE_NAMES, "manifest lanes")
    raise InvalidManifest, "manifest lanes must contain arrays" unless lanes.values.all? { |entries| entries.is_a?(Array) }
    lanes.each_value { |entries| validate_no_forbidden_keys!(entries) }
    raise InvalidManifest, "credential lane must contain references only" if Array(lanes["credentials"]).any? { |entry| !credential_reference?(entry) }
  end

  def self.credential_reference?(entry)
    entry.is_a?(Hash) && entry["lane"] == "credentials" && entry["kind"].present? && entry["locator"].is_a?(Hash) && entry.keys.all? { |key| %w[lane kind locator].include?(key.to_s) }
  end
end
