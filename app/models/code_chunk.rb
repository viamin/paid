# frozen_string_literal: true

class CodeChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :project

  CHUNK_TYPES = %w[file function class module].freeze

  validates :file_path, presence: true
  validates :chunk_type, presence: true, inclusion: { in: CHUNK_TYPES }
  validates :content, presence: true
  validates :content_hash, presence: true

  scope :for_project, ->(project) { where(project: project) }
  scope :with_embedding, -> { where.not(embedding: nil) }
  scope :by_file, ->(path) { where(file_path: path) }

  before_validation :compute_content_hash, if: :content_changed?

  def embedded?
    embedding.present?
  end

  private

  def compute_content_hash
    self.content_hash = Digest::SHA256.hexdigest(content) if content.present?
  end
end
