# frozen_string_literal: true

class ScalingObservation < ApplicationRecord
  belongs_to :project
  belongs_to :issue, optional: true

  before_validation :assign_project_from_issue

  validates :workflow_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :project_id }
  validates :workflow_name, presence: true, length: { maximum: 255 }
  validates :observation_type, presence: true, length: { maximum: 100 }
  validates :status, presence: true, length: { maximum: 100 }
  validates :success, inclusion: { in: [ true, false ] }
  validates :parallel_execution, inclusion: { in: [ true, false ] }
  validate :project_matches_issue
  validate :metadata_is_object

  NUMERIC_FIELDS = %i[
    task_count
    dependency_edge_count
    parallelizable_group_count
    agent_count_planned
    agent_count_launched
    agent_count_succeeded
    agent_count_failed
    agent_count_blocked
    total_iterations
    max_iterations
    parallelism_planned
    parallelism_observed
    batch_count
    duration_seconds
    total_cost_cents
    total_input_tokens
    total_output_tokens
  ].freeze

  NUMERIC_FIELDS.each do |field|
    validates field, numericality: { greater_than_or_equal_to: 0 }, allow_nil: field == :duration_seconds
  end

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_project, ->(project) { where(project: project) }
  scope :for_issue, ->(issue) { where(issue: issue) }
  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) }
  scope :by_observation_type, ->(observation_type) { where(observation_type: observation_type) }
  scope :by_status, ->(status) { where(status: status) }

  private

  def assign_project_from_issue
    self.project ||= issue&.project
  end

  def project_matches_issue
    return unless project && issue
    return if project_id == issue.project_id

    errors.add(:project, "must match the issue's project")
  end

  def metadata_is_object
    return if metadata.is_a?(Hash)

    errors.add(:metadata, "must be an object")
  end
end
