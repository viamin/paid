# frozen_string_literal: true

# One idempotent trusted post-deploy measurement request/evidence record.
# The unique key (issue, check key, check version, deployed revision) makes
# retries and duplicate events converge on the same row; a new deployment
# generation or check version starts a fresh evidence row instead of
# overwriting history. Growth is bounded by that key, so rows are retained
# as inspectable closeout evidence history.
# @spec POST-DEPLOY-004
class PostDeployMeasurement < ApplicationRecord
  STATUSES = %w[pending running awaiting_deployment passed failed unknown].freeze
  RETRY_STATUSES = %w[pending awaiting_deployment].freeze
  MAX_ATTEMPTS = 3
  STALE_RUNNING_AFTER = 1.hour

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :requested_by, class_name: "User", optional: true

  validates :check_key, presence: true
  validates :criterion, presence: true
  validates :check_version, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :status, inclusion: { in: STATUSES }
  # The empty string is the pending sentinel: a generation is stamped with
  # the deployed revision only at execution, so only nil is invalid (the
  # NOT NULL column constraint backs this up).
  validates :deployed_revision, length: { maximum: 200 }, allow_nil: true
  validate :issue_belongs_to_project
  validate :project_belongs_to_account

  scope :due, -> { where(status: RETRY_STATUSES) }
  scope :retryable, -> { where(status: "unknown").where(attempts: ...MAX_ATTEMPTS) }
  scope :actionable, -> { due.or(retryable) }
  # A `running` row whose process died without a terminal update is picked
  # back up once its lock lease is demonstrably stale.
  scope :stale_running, -> { where(status: "running").where(updated_at: ...STALE_RUNNING_AFTER.ago) }

  def terminal? = status.in?(%w[passed failed unknown])

  # Mirrors the +actionable+ scope: due rows (pending or awaiting deployment)
  # plus unknown rows that have not exhausted their attempts.
  def retryable? = status.in?(RETRY_STATUSES) || (status == "unknown" && attempts < MAX_ATTEMPTS)

  def passed? = status == "passed"

  # Evidence is current only for the exact deployment generation it measured
  # and the check version it ran.
  def current_for?(target_revision:, check_version:)
    deployed_revision == target_revision && self.check_version == check_version
  end

  def released? = released_at.present?

  # The latest evidence row for a check on an issue at a given generation.
  def self.latest_for(issue, check_key, check_version: nil)
    scope = where(issue:, check_key:)
    scope = scope.where(check_version:) if check_version
    scope.order(id: :desc).first
  end

  private

  def issue_belongs_to_project
    errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project_id
  end

  def project_belongs_to_account
    errors.add(:project, "must belong to the account") if project && account && project.account_id != account_id
  end
end
