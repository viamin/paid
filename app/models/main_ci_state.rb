# frozen_string_literal: true

# @spec MAIN-CI-002 MAIN-CI-006 MAIN-CI-007
class MainCiState < ApplicationRecord
  include TenantScoped

  belongs_to :project
  belongs_to :repair_run, class_name: "AgentRun", optional: true

  validates :project_id, uniqueness: true
  validates :status, inclusion: { in: %w[unverified healthy failing retrying repair_queued blocked] }
  validates :verified_sha, :observed_sha, :failed_sha, format: { with: /\A[0-9a-f]{40}\z/ }, allow_nil: true
  validate :matching_tenant

  def blocked? = status != "healthy"

  private

  def matching_tenant
    errors.add(:account, "must own project") unless project&.account_id == account_id
    errors.add(:repair_run, "must belong to project") if repair_run && repair_run.project_id != project_id
  end
end
