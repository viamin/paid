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
  validate :tool_renderer_contract
  validate :compatibility_constraints_is_object
  validate :review_metadata_is_object

  def compatibility_for(key)
    compatibility_constraints[key.to_s]
  end

  def self.tool_payload_errors(payload)
    return [ "must be an object" ] unless payload.is_a?(Hash)

    errors = []
    errors << 'install_type must be "tool"' unless payload["install_type"] == "tool"
    errors << "image must be a non-empty string" unless payload["image"].is_a?(String) && payload["image"].strip.present?
    errors << "port must be an integer between 1 and 65535" unless payload["port"].is_a?(Integer) && payload["port"].between?(1, 65_535)
    errors << "env must be an object" if payload.key?("env") && !payload["env"].is_a?(Hash)
    errors << "hardening must be an object" if payload.key?("hardening") && !payload["hardening"].is_a?(Hash)
    errors << "alias must be a non-empty string" if payload.key?("alias") && (!payload["alias"].is_a?(String) || payload["alias"].strip.blank?)
    errors
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

    add_tool_payload_errors(canonical_artifact, :canonical_artifact)
  end

  def tool_renderer_contract
    return unless marketplace_entry&.entry_type == "tool"
    return unless renderers.is_a?(Hash)

    renderers.each do |provider_key, payload|
      add_tool_payload_errors(payload, :renderers, provider_key:)
    end
  end

  def add_tool_payload_errors(payload, attribute, provider_key: nil)
    self.class.tool_payload_errors(payload).each do |message|
      message = "#{provider_key} #{message}" if provider_key
      errors.add(attribute, message)
    end
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
