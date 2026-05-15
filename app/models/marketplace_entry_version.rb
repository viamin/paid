# frozen_string_literal: true

class MarketplaceEntryVersion < ApplicationRecord
  belongs_to :marketplace_entry
  has_many :agent_run_marketplace_entries, dependent: :restrict_with_error

  before_destroy :prevent_destroy_when_attached_to_runs

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :marketplace_entry_id }
  validates :canonical_artifact, presence: true
  validate :canonical_artifact_is_object
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
