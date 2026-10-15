# frozen_string_literal: true

class MarketplaceEntryVersion < ApplicationRecord
  belongs_to :marketplace_entry
  has_many :agent_run_marketplace_entries, dependent: :restrict_with_error

  before_destroy :prevent_destroy_when_attached_to_runs, prepend: true

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :marketplace_entry_id }
  validates :canonical_artifact, presence: true
  validate :canonical_artifact_is_object
  validate :tool_canonical_artifact_contract
  validate :renderers_is_object
  validate :renderer_payloads_are_objects
  validate :compatibility_constraints_is_object
  validate :review_metadata_is_object

  def compatibility_for(key)
    compatibility_constraints[key.to_s]
  end

  private

  def prevent_destroy_when_attached_to_runs
    return true unless agent_run_marketplace_entries.exists?

    errors.add(:base, "cannot delete marketplace entry versions that have been attached to agent runs")
    throw(:abort)
  end

  def canonical_artifact_is_object
    errors.add(:canonical_artifact, "must be an object") unless canonical_artifact.is_a?(Hash)
  end

  # @spec TOOL-SIDECAR-001
  def tool_canonical_artifact_contract
    return unless marketplace_entry&.entry_type == "tool"
    return unless canonical_artifact.is_a?(Hash)

    validate_tool_install_type
    validate_tool_image
    validate_tool_port
    validate_tool_optionals
  end

  def validate_tool_install_type
    return if canonical_artifact["install_type"] == "tool"

    errors.add(:canonical_artifact, "install_type must be \"tool\"")
  end

  def validate_tool_image
    return if canonical_artifact["image"].is_a?(String) && canonical_artifact["image"].strip.present?

    errors.add(:canonical_artifact, "image must be a non-empty string")
  end

  def validate_tool_port
    port = canonical_artifact["port"]
    return if port.is_a?(Integer) && port.between?(1, 65_535)

    errors.add(:canonical_artifact, "port must be an integer between 1 and 65535")
  end

  def validate_tool_optionals
    validate_tool_object("env")
    validate_tool_alias
    validate_tool_object("hardening")
  end

  def validate_tool_object(key)
    return if !canonical_artifact.key?(key) || canonical_artifact[key].is_a?(Hash)

    errors.add(:canonical_artifact, "#{key} must be an object")
  end

  def validate_tool_alias
    alias_name = canonical_artifact["alias"]
    return unless canonical_artifact.key?("alias")
    return if alias_name.is_a?(String) && alias_name.strip.present?

    errors.add(:canonical_artifact, "alias must be a non-empty string")
  end

  def renderers_is_object
    errors.add(:renderers, "must be an object") unless renderers.is_a?(Hash)
  end

  def renderer_payloads_are_objects
    return unless renderers.is_a?(Hash)

    invalid_provider_keys = renderers.each_with_object([]) do |(provider_key, payload), keys|
      keys << provider_key unless payload.is_a?(Hash)
    end
    return if invalid_provider_keys.empty?

    errors.add(:renderers, "must map provider keys to objects (invalid: #{invalid_provider_keys.join(', ')})")
  end

  def compatibility_constraints_is_object
    errors.add(:compatibility_constraints, "must be an object") unless compatibility_constraints.is_a?(Hash)
  end

  def review_metadata_is_object
    errors.add(:review_metadata, "must be an object") unless review_metadata.is_a?(Hash)
  end
end
