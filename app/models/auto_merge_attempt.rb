# frozen_string_literal: true

# @spec AUTO-MERGE-004
class AutoMergeAttempt < ApplicationRecord
  REASON_AUTO_MERGE_DISABLED = "auto_merge_disabled"
  REASON_CHECKS_NOT_GREEN = "checks_not_green"
  REASON_EXPECTED_MERGE_FAILURE = "expected_merge_failure"
  REASON_GRANULARITY_MISMATCH = "granularity_mismatch"
  REASON_MERGE_PERMISSION_COOLDOWN = "merge_permission_cooldown"
  REASON_MISSING_WORKFLOWS_PERMISSION = "missing_workflows_permission"
  REASON_NOT_MERGEABLE = "not_mergeable"
  REASON_PARSE_FAILED = "parse_failed"
  REASON_SKIP_LABEL = "skip_label"

  CREDENTIAL_MODE_GITHUB_APP = "github_app"
  CREDENTIAL_MODE_PAT = "pat"
  CREDENTIAL_MODE_PAT_FALLBACK = "pat_fallback"

  STATUSES = %w[merged skipped blocked failed].freeze
  CREDENTIAL_MODES = [
    CREDENTIAL_MODE_GITHUB_APP,
    CREDENTIAL_MODE_PAT,
    CREDENTIAL_MODE_PAT_FALLBACK
  ].freeze

  belongs_to :project
  belongs_to :issue

  validates :attempted_at, :actor_path, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :credential_mode, inclusion: { in: CREDENTIAL_MODES }, allow_nil: true
  validate :issue_belongs_to_project

  scope :recent, -> { order(attempted_at: :desc, id: :desc) }
  scope :permission_blockers, -> { where(reason_code: REASON_MISSING_WORKFLOWS_PERMISSION) }

  def self.primary_credential_mode(project)
    project.github_auth_source == "app" ? CREDENTIAL_MODE_GITHUB_APP : CREDENTIAL_MODE_PAT
  end

  private

  def issue_belongs_to_project
    return if issue.blank? || project.blank? || issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end
end
