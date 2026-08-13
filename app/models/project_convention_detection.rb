# frozen_string_literal: true

class ProjectConventionDetection < ApplicationRecord
  belongs_to :project
  belongs_to :project_version

  before_validation :assign_category

  delegate :commit_sha, to: :project_version, prefix: :project_version

  validates :category, presence: true, length: { maximum: 100 }
  validates :key, presence: true, length: { maximum: 100 }
  validates :detector_key, presence: true, length: { maximum: 100 }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :detected_at, presence: true
  validate :value_is_object
  validate :evidence_is_object
  validate :project_matches_project_version

  scope :for_key, ->(key) { where(key: key.to_s) }
  scope :by_confidence, -> { order(confidence: :desc, detected_at: :desc, id: :desc) }

  private

  def project_matches_project_version
    return unless project_version

    if project_id.present? && project_version.project_id != project_id
      errors.add(:project, "must match the project version's project")
    else
      self.project_id ||= project_version.project_id
    end
  end

  def assign_category
    self.category = ProjectConventions::Catalog.category_for(key) if key.present?
  end

  def value_is_object
    errors.add(:value, "must be an object") unless value.is_a?(Hash)
  end

  def evidence_is_object
    errors.add(:evidence, "must be an object") unless evidence.is_a?(Hash)
  end
end
