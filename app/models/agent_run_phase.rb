# frozen_string_literal: true

class AgentRunPhase < ApplicationRecord
  PHASE_GROUPS = %w[setup prompt agent post cleanup].freeze
  STATUSES = %w[completed failed].freeze

  PHASE_LABELS = {
    "create_agent_run" => "Create Agent Run",
    "provision_services" => "Provision Services",
    "provision_container" => "Provision Container",
    "clone_repo" => "Clone Repo",
    "rebase_branch" => "Rebase Branch",
    "prepare_pr_prompt" => "Prepare PR Prompt",
    "run_agent" => "Run Agent",
    "complete_issue_goal" => "Complete Issue Goal",
    "create_github_issue" => "Create GitHub Issue",
    "push_branch" => "Push Branch",
    "create_pull_request" => "Create Pull Request",
    "update_issue_with_pr" => "Update Issue With PR",
    "complete_existing_pr_run" => "Complete Existing PR Run",
    "mark_agent_run_complete" => "Mark Agent Run Complete",
    "cleanup_container" => "Cleanup Container",
    "cleanup_services" => "Cleanup Services",
    "cleanup_worktree" => "Cleanup Worktree"
  }.freeze

  belongs_to :agent_run

  validates :phase_key, presence: true, length: { maximum: 100 }
  validates :phase_group, presence: true, inclusion: { in: PHASE_GROUPS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :started_at, :finished_at, presence: true

  scope :ordered, -> { order(:started_at, :id) }

  def self.record!(agent_run:, phase_key:, phase_group:, started_at:, finished_at:, status: "completed", metadata: {})
    create!(
      agent_run: agent_run,
      phase_key: phase_key,
      phase_group: phase_group,
      status: status,
      started_at: started_at,
      finished_at: finished_at,
      duration_seconds: [ (finished_at - started_at).to_i, 0 ].max,
      metadata: metadata
    )
  end

  def label
    PHASE_LABELS.fetch(phase_key, phase_key.to_s.tr("_", " ").titleize)
  end
end
