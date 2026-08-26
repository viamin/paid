# frozen_string_literal: true

# @spec AUTO-MERGE-004
class AutoMergeAttempt < ApplicationRecord
  STATUSES = %w[merged skipped blocked failed].freeze
  CREDENTIAL_MODES = %w[github_app pat pat_fallback].freeze

  belongs_to :project
  belongs_to :issue

  validates :attempted_at, :actor_path, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :credential_mode, inclusion: { in: CREDENTIAL_MODES }, allow_nil: true
  validate :issue_belongs_to_project

  scope :recent, -> { order(attempted_at: :desc, id: :desc) }
  scope :permission_blockers, -> { where(reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION) }

  private

  def issue_belongs_to_project
    return if issue.blank? || project.blank? || issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end
end
