# frozen_string_literal: true

# @spec POST-DEPLOY-CHECK-001
class PostDeployCheckRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed unknown].freeze

  include TenantScoped

  belongs_to :project
  belongs_to :source_issue, class_name: "Issue", optional: true
  belongs_to :superseded_by, class_name: "PostDeployCheckRun", optional: true

  validates :check_key, :check_version, :idempotency_key, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validate :tenant_owns_associations

  scope :current, -> { where(superseded_by_id: nil) }
  scope :for_check, ->(check_key) { where(check_key: check_key) }

  def succeeded? = status == "succeeded"
  def failed? = status == "failed"
  def unknown? = status == "unknown"

  private

  def tenant_owns_associations
    errors.add(:project, "must belong to the run's account") if project.present? && project.account_id != account_id
    errors.add(:source_issue, "must belong to the run's account") if source_issue.present? && source_issue.project.account_id != account_id
    errors.add(:superseded_by, "must belong to the run's account") if superseded_by.present? && superseded_by.account_id != account_id
  end
end
