# frozen_string_literal: true

class QualityRecoveryAction < ApplicationRecord
  ACTION_TYPES = %w[
    prompt_rollback
    prompt_evolution
    model_change
    model_escalation
    config_adjustment
    resume_with_monitoring
    final_pause
  ].freeze
  STATUSES = %w[pending executing executed evaluated failed].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :prompt_version, optional: true

  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :quality_before, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :quality_after, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true

  scope :by_project, ->(project_id) { where(project_id: project_id) }
  scope :recent, -> { order(created_at: :desc) }
  scope :effective, -> { where(status: "evaluated").where("quality_after > quality_before") }

  def effective?
    quality_before.present? && quality_after.present? && quality_after > quality_before
  end

  def quality_delta
    return nil unless quality_before.present? && quality_after.present?

    quality_after - quality_before
  end

  def execute!
    update!(status: "executing", executed_at: Time.current)
  end

  def complete!(result_data = {})
    update!(status: "executed", result: result_data)
  end

  def evaluate!(score)
    update!(status: "evaluated", quality_after: score, evaluated_at: Time.current)
  end

  def fail!(error_data = {})
    update!(status: "failed", result: result.merge(error: error_data))
  end
end
