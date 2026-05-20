# frozen_string_literal: true

class ProjectConventionDetection < ApplicationRecord
  belongs_to :project
  belongs_to :project_version

  validates :key, presence: true, length: { maximum: 100 }
  validates :detector_key, presence: true, length: { maximum: 100 }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :detected_at, presence: true
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
end
