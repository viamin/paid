# frozen_string_literal: true

# @spec MAIN-CI-001 MAIN-CI-007
class MainCiSweepJob < ApplicationJob
  queue_as :default
  self.perform_timeout = 60

  def perform
    projects = TenantContext.with_system_access do
      Project.active.where("review_settings @> ?::jsonb", { main_ci_recovery: { enabled: true } }.to_json).pluck(:id, :account_id)
    end
    projects.each do |id, account_id|
      account = TenantContext.with_system_access { Account.find(account_id) }
      TenantContext.with(account) { MainCiReconciliationJob.perform_later(id) }
    end
  end
end
