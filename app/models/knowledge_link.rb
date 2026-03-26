# frozen_string_literal: true

class KnowledgeLink < ApplicationRecord
  LINK_TYPES = %w[calls implements tests relates_to depends_on supersedes].freeze

  belongs_to :source_chunk, class_name: "KnowledgeChunk", inverse_of: :outgoing_links
  belongs_to :target_chunk, class_name: "KnowledgeChunk", inverse_of: :incoming_links

  validates :link_type, presence: true, inclusion: { in: LINK_TYPES }
  validates :source_chunk_id, uniqueness: { scope: [ :target_chunk_id, :link_type ] }
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
