# frozen_string_literal: true

class KnowledgeChunk < ApplicationRecord
  belongs_to :knowledge_artifact
  belongs_to :project

  validates :chunk_type, presence: true
  validates :content, presence: true
  validates :content_hash, presence: true
  validates :status, presence: true

  scope :active, -> { where(status: "active") }
end
