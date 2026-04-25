# frozen_string_literal: true

class KnowledgeUsageStat < ApplicationRecord
  belongs_to :agent_run
  belongs_to :project

  validates :artifact_type, presence: true, length: { maximum: 100 }
  validates :goal, presence: true, length: { maximum: 50 }
  validates :context_type, presence: true, length: { maximum: 50 }
  validates :artifact_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :chunk_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :token_count, numericality: { greater_than_or_equal_to: 0 }

  CONTEXT_TYPES = %w[bundle search].freeze

  scope :for_project, ->(project) { where(project_id: project.id) }
  scope :by_artifact_type, ->(type) { where(artifact_type: type) }
  scope :by_goal, ->(goal) { where(goal: goal) }
  scope :since, ->(time) { where(created_at: time..) }
end
