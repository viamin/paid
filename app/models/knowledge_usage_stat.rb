# frozen_string_literal: true

class KnowledgeUsageStat < ApplicationRecord
  belongs_to :agent_run
  belongs_to :project

  CONTEXT_TYPES = %w[bundle search].freeze

  before_validation :assign_defaults_from_agent_run

  validates :artifact_type, presence: true, length: { maximum: 100 }
  validates :goal, presence: true, length: { maximum: 50 }
  validates :context_type, presence: true, length: { maximum: 50 }, inclusion: { in: CONTEXT_TYPES }
  validates :artifact_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :chunk_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :token_count, numericality: { greater_than_or_equal_to: 0 }
  validate :project_matches_agent_run
  validate :goal_matches_agent_run

  scope :for_project, ->(project) { where(project: project) }
  scope :by_artifact_type, ->(type) { where(artifact_type: type) }
  scope :by_goal, ->(goal) { where(goal: goal) }
  scope :since, ->(time) { where(created_at: time..) }

  private

  def assign_defaults_from_agent_run
    self.project ||= agent_run&.project
    self.goal ||= agent_run&.goal
  end

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  def goal_matches_agent_run
    return unless goal && agent_run&.goal

    errors.add(:goal, "must match the agent run's goal") if goal != agent_run.goal
  end
end
