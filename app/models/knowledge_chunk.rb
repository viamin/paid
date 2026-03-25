# frozen_string_literal: true

class KnowledgeChunk < ApplicationRecord
  STATUSES = %w[active stale deleted redacted].freeze

  belongs_to :knowledge_artifact
  belongs_to :project

  has_many :outgoing_links, class_name: "KnowledgeLink",
    foreign_key: :source_chunk_id, dependent: :destroy, inverse_of: :source_chunk
  has_many :incoming_links, class_name: "KnowledgeLink",
    foreign_key: :target_chunk_id, dependent: :destroy, inverse_of: :target_chunk

  validates :chunk_type, presence: true, length: { maximum: 50 }
  validates :content, presence: true
  validates :content_hash, presence: true, length: { maximum: 64 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :for_project, ->(project) { where(project: project) }
end
