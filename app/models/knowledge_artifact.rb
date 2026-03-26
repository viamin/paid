# frozen_string_literal: true

class KnowledgeArtifact < ApplicationRecord
  belongs_to :collector_run
  belongs_to :project

  has_many :knowledge_chunks, dependent: :destroy

  validates :artifact_type, presence: true
  validates :content_hash, presence: true
  validates :status, presence: true
end
