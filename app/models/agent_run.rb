# frozen_string_literal: true

class AgentRun < ApplicationRecord
  STATUSES = %w[pending running completed failed cancelled timeout].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot api].freeze

  belongs_to :project
  belongs_to :issue, optional: true

  has_many :agent_run_logs, dependent: :destroy

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :worktree_path, length: { maximum: 500 }
  validates :branch_name, length: { maximum: 255 }
  validates :base_commit_sha, length: { maximum: 40 }
  validates :result_commit_sha, length: { maximum: 40 }
  validates :pull_request_url, length: { maximum: 500 }
  validates :temporal_workflow_id, length: { maximum: 255 }
  validates :temporal_run_id, length: { maximum: 255 }
  validate :issue_belongs_to_same_project, if: -> { issue.present? }

  scope :by_status, ->(status) { where(status: status) }
  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :timeout, -> { where(status: "timeout") }
  scope :active, -> { where(status: %w[pending running]) }
  scope :finished, -> { where(status: %w[completed failed cancelled timeout]) }
  scope :recent, -> { order(created_at: :desc) }

  def duration
    return nil unless started_at

    end_time = completed_at || Time.current
    (end_time - started_at).to_i
  end

  def running?
    status == "running"
  end

  def finished?
    %w[completed failed cancelled timeout].include?(status)
  end

  def successful?
    status == "completed"
  end

  def total_tokens
    tokens_input + tokens_output
  end

  def start!
    update!(status: "running", started_at: Time.current)
  end

  def complete!(result_commit: nil, pr_url: nil, pr_number: nil)
    update!(
      status: "completed",
      completed_at: Time.current,
      result_commit_sha: result_commit,
      pull_request_url: pr_url,
      pull_request_number: pr_number,
      duration_seconds: duration
    )
  end

  def fail!(error: nil)
    update!(
      status: "failed",
      completed_at: Time.current,
      error_message: error,
      duration_seconds: duration
    )
  end

  def cancel!
    update!(
      status: "cancelled",
      completed_at: Time.current,
      duration_seconds: duration
    )
  end

  def timeout!
    update!(
      status: "timeout",
      completed_at: Time.current,
      duration_seconds: duration
    )
  end

  private

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end
end
