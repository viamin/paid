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
  INPUT_SECTION_SHAPES = {
    "source" => { "digest" => :digest, "commit_sha" => :string, "bundle_digest" => :digest },
    "verification" => { "operations" => :capabilities, "workflow_digest" => :digest },
    "profile" => { "digest" => :digest, "platform" => :platform, "xcode_version" => :string }
  }.freeze
  OUTPUT_SECTION_FIELDS = {
    "attempt" => %w[id source_digest workflow_revision lifecycle_gate profile_digest],
    "result" => %w[status timings retry_lineage failure_classification required_checks advisory_checks screenshot_metadata network_policy audit_event_references ledger_entry_references],
    "artifacts" => %w[xcresult build_logs screenshots diagnostics references]
  }.freeze
  OUTPUT_SECTION_SHAPES = {
    "attempt" => { "id" => :identifier, "source_digest" => :digest, "workflow_revision" => :identifier, "lifecycle_gate" => :lifecycle_gate, "profile_digest" => :digest },
    "result" => { "status" => :string, "timings" => :timings, "retry_lineage" => :identifier_array, "failure_classification" => :string, "required_checks" => :string_array, "advisory_checks" => :string_array, "screenshot_metadata" => :reference_array, "network_policy" => :network_policy, "audit_event_references" => :reference_array, "ledger_entry_references" => :reference_array },
    "artifacts" => { "xcresult" => :reference_array, "build_logs" => :reference_array, "screenshots" => :reference_array, "diagnostics" => :reference_array, "references" => :reference_array }
  }.freeze
  DIGEST_PATTERN = /\Asha256:[a-f0-9]{64}\z/
  TIMING_FIELDS = %w[queued_ms provisioning_ms running_ms total_ms].freeze
  NETWORK_POLICY_FIELDS = %w[mode egress_profile].freeze
  LOCATOR_FIELDS = {
    "git" => %w[repository_id repo_full_name commit_sha ref bundle_digest],
    "control_plane_api" => %w[id project_id workflow_revision_id attempt_id artifact_id audit_event_id],
    "object_storage" => %w[id key digest sha256 url],
    "credentials" => %w[credential_id name project_id account_id repository_id integration_credential_id github_token_id]
  }.freeze

  class UnsupportedCapability < StandardError; end
  class InvalidManifest < StandardError; end
  class InvalidVersionConstraint < ArgumentError; end

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
    VersionRequirement.parse(self.xcode_version)
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
    validate_manifest!(manifest, allowed_fields: INPUT_MANIFEST_FIELDS, section_fields: INPUT_SECTION_FIELDS, section_shapes: INPUT_SECTION_SHAPES)
  end

  def self.validate_output_manifest!(manifest)
    validate_manifest!(manifest, allowed_fields: OUTPUT_MANIFEST_FIELDS, section_fields: OUTPUT_SECTION_FIELDS, section_shapes: OUTPUT_SECTION_SHAPES)
  end

  def self.validate_manifest!(manifest, allowed_fields:, section_fields:, section_shapes:)
    validate_object!(manifest)
    validate_schema_version!(manifest)
    validate_allowed_fields!(manifest, allowed_fields, "manifest")
    validate_section_fields!(manifest, section_fields)
    validate_no_forbidden_keys!(manifest.except("lanes"))
    validate_section_shapes!(manifest, section_shapes)
    validate_no_secret_shaped_values!(manifest)
    validate_lanes!(manifest.fetch("lanes"))
  end

  def self.validate_object!(value)
    raise InvalidManifest, "manifest must be an object" unless value.is_a?(Hash)
  end

  def self.validate_schema_version!(manifest)
    return if manifest["schema_version"] == MANIFEST_SCHEMA_VERSION

    raise InvalidManifest, "unsupported manifest schema_version #{manifest["schema_version"].inspect}"
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

  def self.validate_section_shapes!(manifest, section_shapes)
    section_shapes.each do |section, fields|
      manifest.fetch(section).each do |field, value|
        validate_field_shape!(value, fields.fetch(field.to_s))
      end
    end
  end

  def self.validate_field_shape!(value, shape)
    valid = case shape
    when :digest then value.is_a?(String) && value.match?(DIGEST_PATTERN)
    when :string then value.is_a?(String)
    when :identifier then value.is_a?(String) || value.is_a?(Integer)
    when :platform then value.is_a?(String) && PLATFORMS.include?(value)
    when :lifecycle_gate then AppleVerificationWorkflowRevision::LIFECYCLE_GATES.include?(value)
    when :capabilities then value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) && CAPABILITIES.include?(entry.to_sym) }
    when :string_array then value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
    when :identifier_array then value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) || entry.is_a?(Integer) }
    when :reference_array then value.is_a?(Array) && value.all? { |entry| lane_reference?(entry) }
    when :timings then timings?(value)
    when :network_policy then network_policy?(value)
    end
    raise InvalidManifest, "manifest field has an invalid shape" unless valid
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
    lanes.each do |lane, entries|
      raise InvalidManifest, "manifest lane must contain references only" unless entries.all? { |entry| lane_reference?(entry, lane:) }
    end
  end

  def self.lane_reference?(entry, lane: nil)
    return false unless entry.is_a?(Hash) && entry["lane"].in?(LANE_NAMES) && entry["kind"].is_a?(String) && entry["kind"].present?
    return false unless lane.nil? || entry["lane"] == lane
    return false unless entry.keys.all? { |key| %w[lane kind locator].include?(key.to_s) }

    locator = entry["locator"]
    locator.is_a?(Hash) && locator.present? && locator.keys.all? { |key| LOCATOR_FIELDS.fetch(entry["lane"]).include?(key.to_s) } && locator.values.all? { |value| value.is_a?(String) || value.is_a?(Integer) }
  end

  def self.timings?(value)
    value.is_a?(Hash) && (value.keys.map(&:to_s) - TIMING_FIELDS).empty? && value.values.all? { |duration| duration.is_a?(Numeric) && duration >= 0 }
  end

  def self.network_policy?(value)
    value.is_a?(Hash) && (value.keys.map(&:to_s) - NETWORK_POLICY_FIELDS).empty? && value.values.all? { |policy| policy.is_a?(String) }
  end
end
