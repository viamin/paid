# frozen_string_literal: true

class KnowledgeArtifact < ApplicationRecord
  STATUSES = %w[active stale deleted].freeze

  belongs_to :collector_run
  belongs_to :project

  has_many :knowledge_chunks, dependent: :destroy

  validates :artifact_type, presence: true, length: { maximum: 100 }
  validates :content_hash, presence: true, length: { maximum: 64 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :stale, -> { where(status: "stale") }
  scope :by_type, ->(type) { where(artifact_type: type) }
  scope :for_project, ->(project) { where(project: project) }
end
