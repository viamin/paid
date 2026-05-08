# frozen_string_literal: true

class FailureClassification < ApplicationRecord
  FAILURE_CATEGORIES = %w[
    provider_error
    timeout
    auth_failure
    rate_limit
    container_error
    prompt_error
    dependency_failure
    configuration_error
    unknown
  ].freeze

  ACTIONS = %w[
    retry_same_provider
    retry_alternate_provider
    escalate_model
    cancel_workflow
    pause_and_notify
    skip_and_continue
    reconfigure_and_retry
  ].freeze

  ACTION_STATUSES = %w[pending executing completed skipped].freeze

  belongs_to :project
  belongs_to :agent_run

  validates :failure_category, presence: true, inclusion: { in: FAILURE_CATEGORIES }
  validates :chosen_action, presence: true, inclusion: { in: ACTIONS }
  validates :action_status, presence: true, inclusion: { in: ACTION_STATUSES }
  validates :parent_workflow_id, length: { maximum: 255 }

  scope :by_project, ->(project_id) { where(project_id: project_id) }
  scope :by_category, ->(category) { where(failure_category: category) }
  scope :by_action, ->(action) { where(chosen_action: action) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_workflow, ->(workflow_id) { where(parent_workflow_id: workflow_id) }
  scope :completed, -> { where(action_status: "completed") }

  def execute!
    update!(action_status: "executing", executed_at: Time.current)
  end

  def complete!(result_data = {})
    update!(action_status: "completed", action_result: result_data, completed_at: Time.current)
  end

  def skip!(reason = nil)
    result = reason ? { skip_reason: reason } : {}
    update!(action_status: "skipped", action_result: action_result.merge(result))
  end
end
