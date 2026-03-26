# frozen_string_literal: true

class KnowledgeChunk < ApplicationRecord
  STATUSES = %w[active stale deleted redacted].freeze
  CHUNK_TYPES = %w[definition summary context evidence].freeze

  belongs_to :knowledge_artifact
  belongs_to :project

  has_many :source_links, class_name: "KnowledgeLink", foreign_key: :source_chunk_id,
    dependent: :destroy, inverse_of: :source_chunk
  has_many :target_links, class_name: "KnowledgeLink", foreign_key: :target_chunk_id,
    dependent: :destroy, inverse_of: :target_chunk

  validates :chunk_type, presence: true, inclusion: { in: CHUNK_TYPES }
  validates :content, presence: true
  validates :content_hash, presence: true, length: { maximum: 64 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :project_matches_knowledge_artifact_project

  scope :active, -> { where(status: "active") }
  scope :embeddable, -> { active.where.not(embedding_model: nil) }
  scope :by_project, ->(project_id) { where(project_id: project_id) }
  scope :ordered, -> { order(:sequence) }

  private

  def project_matches_knowledge_artifact_project
    return if knowledge_artifact.nil? || project_id.nil?
    return if knowledge_artifact.project_id == project_id

    errors.add(:project, "must match knowledge artifact's project")
  end
end
