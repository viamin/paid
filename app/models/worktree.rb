# frozen_string_literal: true

class Worktree < ApplicationRecord
  STATUSES = %w[active cleaned cleanup_failed].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :path, presence: true
  validates :branch_name, presence: true, uniqueness: { scope: :project_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :base_commit, length: { maximum: 40 }

  scope :active, -> { where(status: "active") }
  scope :cleaned, -> { where(status: "cleaned") }
  scope :stale, ->(threshold = 24.hours) { active.where("created_at < ?", threshold.ago) }
  scope :orphaned, -> {
    active.left_joins(:agent_run)
      .where(
        "agent_runs.status IN (?) OR agent_runs.id IS NULL OR worktrees.created_at < ?",
        %w[completed failed cancelled timeout],
        24.hours.ago
      )
  }

  def active?
    status == "active"
  end

  def cleaned?
    status == "cleaned"
  end

  def pushed?
    pushed
  end

  def mark_pushed!
    update!(pushed: true)
  end

  def mark_cleaned!
    update!(status: "cleaned", cleaned_at: Time.current)
  end

  def mark_cleanup_failed!
    update!(status: "cleanup_failed")
  end
end
