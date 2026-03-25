# frozen_string_literal: true

class KnowledgeLink < ApplicationRecord
  belongs_to :source_chunk, class_name: "KnowledgeChunk"
  belongs_to :target_chunk, class_name: "KnowledgeChunk"

  validates :link_type, presence: true, length: { maximum: 50 }
  validates :source_chunk_id, uniqueness: { scope: [ :target_chunk_id, :link_type ] }
end
