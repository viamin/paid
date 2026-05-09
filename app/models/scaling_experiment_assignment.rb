# frozen_string_literal: true

class ScalingExperimentAssignment < ApplicationRecord
  OUTCOME_STATUSES = %w[assigned recorded skipped].freeze

  belongs_to :scaling_experiment
  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :scaling_observation, optional: true

  before_validation :assign_project_from_experiment

  validates :workflow_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :scaling_experiment_id }
  validates :assigned_value, numericality: { only_integer: true, greater_than: 0 }
  validates :outcome_status, inclusion: { in: OUTCOME_STATUSES }
  validate :project_matches_experiment
  validate :project_matches_observation
  validate :execution_plan_is_object
  validate :outcome_summary_is_object

  scope :recorded, -> { where(outcome_status: "recorded") }

  private

  def assign_project_from_experiment
    self.project ||= scaling_experiment&.project
  end

  def project_matches_experiment
    return unless scaling_experiment && project
    return if scaling_experiment.project_id == project_id

    errors.add(:project, "must match the experiment project")
  end

  def project_matches_observation
    return unless scaling_observation && project
    return if scaling_observation.project_id == project_id

    errors.add(:scaling_observation, "must belong to the same project")
  end

  def execution_plan_is_object
    return if execution_plan.is_a?(Hash)

    errors.add(:execution_plan, "must be an object")
  end

  def outcome_summary_is_object
    return if outcome_summary.is_a?(Hash)

    errors.add(:outcome_summary, "must be an object")
  end
end
