# frozen_string_literal: true

class CodeChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :project

  CHUNK_TYPES = %w[file function class module method].freeze
  SUPPORTED_LANGUAGES = %w[ruby javascript typescript python go rust].freeze

  validates :file_path, presence: true
  validates :chunk_type, presence: true, inclusion: { in: CHUNK_TYPES }
  validates :content, presence: true
  validates :content_hash, presence: true

  scope :for_language, ->(lang) { where(language: lang) }
  scope :for_chunk_type, ->(type) { where(chunk_type: type) }
  scope :with_embeddings, -> { where.not(embedding: nil) }
  scope :without_embeddings, -> { where(embedding: nil) }

  before_validation :compute_content_hash, if: :content_changed?

  def self.search_by_embedding(embedding, limit: 10)
    with_embeddings.nearest_neighbors(:embedding, embedding, distance: :cosine).limit(limit)
  end

  def embedded?
    embedding.present?
  end

  def stale?(new_content)
    content_hash != Digest::SHA256.hexdigest(new_content)
  end

  private

  def compute_content_hash
    self.content_hash = Digest::SHA256.hexdigest(content) if content.present?
  end
end
