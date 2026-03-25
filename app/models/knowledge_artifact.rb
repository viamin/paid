# frozen_string_literal: true

class KnowledgeArtifact < ApplicationRecord
  STATUSES = %w[active stale deleted].freeze

  belongs_to :collector_run
  belongs_to :project

  has_many :knowledge_chunks, dependent: :destroy

  validates :artifact_type, presence: true, length: { maximum: 100 }
  validates :content_hash, presence: true, length: { maximum: 64 },
    uniqueness: { scope: :collector_run_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :scope_path, length: { maximum: 1000 }, allow_nil: true
  validates :identifier, length: { maximum: 500 }, allow_nil: true
  validate :project_matches_collector_run

  scope :active, -> { where(status: "active") }
  scope :stale, -> { where(status: "stale") }
  scope :by_type, ->(type) { where(artifact_type: type) }

  private

  def project_matches_collector_run
    return unless collector_run&.project_version

    collector_project_id = collector_run.project_version.project_id
    if project_id.present? && collector_project_id.present? && project_id != collector_project_id
      errors.add(:project, "must match the collector run's project")
    elsif project_id.nil? && collector_project_id.present?
      self.project_id = collector_project_id
    end
  end
end
