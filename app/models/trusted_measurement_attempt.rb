# frozen_string_literal: true

# One idempotent attempt to collect a trusted, allowlisted, read-only
# post-deploy measurement against a tenant's own live data, bound to the
# issue/criterion it attests, the deployed revision it was collected against,
# and the check version that produced it. A row never fabricates a pass: a
# missing deployment signal or an execution failure is recorded as its own
# status rather than as "succeeded".
#
# @spec TRUSTED-MEASUREMENTS-001
class TrustedMeasurementAttempt < ApplicationRecord
  STATUSES = %w[pending succeeded failed unknown].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue, optional: true

  validates :external_issue_number, presence: true
  validates :criterion_key, presence: true
  validates :check_key, presence: true, inclusion: { in: -> { TrustedMeasurements::ALLOWLIST.keys } }
  validates :check_version, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :account_matches_scope

  scope :for_check, ->(check_key) { where(check_key: check_key) }
  scope :current_first, -> { order(executed_at: :desc, id: :desc) }

  def succeeded? = status == "succeeded"
  def unknown? = status == "unknown"
  def failed? = status == "failed"

  # A row's evidence is only "current" when it was collected against the
  # revision Paid believes is deployed right now. A row collected against an
  # older revision remains a historical attempt, never current evidence.
  def current_for_revision?(revision)
    deployed_revision.present? && revision.present? && deployed_revision == revision
  end

  private

  def account_matches_scope
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
    errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project.id
  end
end
