# frozen_string_literal: true

class WorkflowState < ApplicationRecord
  FINISHED_STATUSES = %w[completed failed cancelled timed_out].freeze
  STATUSES = (%w[running] + FINISHED_STATUSES).freeze

  belongs_to :project, optional: true

  validates :temporal_workflow_id, presence: true, uniqueness: true
  validates :workflow_type, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "running") }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  # Upserts the polling workflow state for a project and broadcasts the change.
  # Called by ProjectWorkflowManager on start/restart and by PollWorkflowHealthCheckJob.
  def self.record_polling_status(project, status:, restart_reason: nil, error_message: nil)
    workflow_id = "github-poll-#{project.id}"

    ws = find_or_initialize_by(temporal_workflow_id: workflow_id)
    ws.assign_attributes(
      project: project,
      workflow_type: "GitHubPollWorkflow",
      status: status,
      restart_reason: restart_reason,
      error_message: error_message,
      started_at: status == "running" ? Time.current : ws.started_at,
      completed_at: FINISHED_STATUSES.include?(status) ? Time.current : nil
    )
    should_broadcast = ws.new_record? || ws.status_changed?
    ws.save!

    # Broadcast after the transaction commits so listeners never see data that
    # could be rolled back. Skip when status is unchanged (e.g., healthy →
    # healthy on every poll cycle) to avoid unnecessary DB queries and
    # ActionCable traffic.
    if should_broadcast
      ActiveRecord.after_all_transactions_commit { project.broadcast_workflow_status_update }
    end

    ws
  end

  # Computes automation health for a project from the latest WorkflowState,
  # avoiding a Temporal RPC call. Returns nil if no record exists (caller
  # should fall back to Temporal).
  def self.compute_health_for(project)
    unless project.active?
      return {
        status: :inactive,
        label: "Paused",
        description: "Issue monitoring is paused. Activate the project to resume."
      }
    end

    ws = find_by(temporal_workflow_id: "github-poll-#{project.id}")
    return nil unless ws

    ws.automation_health(project)
  end

  def automation_health(project)
    unless running?
      description = "The issue monitor is not running. " \
                    "It may be automatically restarted shortly if eligible."
      description = "#{description} Last error: #{error_message}" if error_message.present?
      return {
        status: :unhealthy,
        label: "Not running",
        description: description,
        restart_reason: restart_reason
      }
    end

    if project.poll_stale_with_recheck?
      description = "The issue monitor appears to be behind schedule. " \
                    "It will be automatically recovered."
      description = "#{description} Last restart: #{restart_reason}" if restart_reason.present?
      return {
        status: :stale,
        label: "Delayed",
        description: description,
        restart_reason: restart_reason
      }
    end

    {
      status: :healthy,
      label: "Active",
      description: "Paid is monitoring this repository for labeled issues."
    }
  end

  def running?
    status == "running"
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end
end
