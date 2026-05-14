# frozen_string_literal: true

class MarketplaceEntryVersion < ApplicationRecord
  belongs_to :marketplace_entry

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :marketplace_entry_id }
  validates :canonical_artifact, presence: true
  validate :canonical_artifact_is_object
  validate :renderers_is_object
  validate :compatibility_constraints_is_object
  validate :review_metadata_is_object

  def compatibility_for(key)
    compatibility_constraints[key.to_s]
  end

  private

  def canonical_artifact_is_object
    errors.add(:canonical_artifact, "must be an object") unless canonical_artifact.is_a?(Hash)
  end

  def renderers_is_object
    errors.add(:renderers, "must be an object") unless renderers.is_a?(Hash)
  end

  def compatibility_constraints_is_object
    errors.add(:compatibility_constraints, "must be an object") unless compatibility_constraints.is_a?(Hash)
  end

  def review_metadata_is_object
    errors.add(:review_metadata, "must be an object") unless review_metadata.is_a?(Hash)
  end
end
