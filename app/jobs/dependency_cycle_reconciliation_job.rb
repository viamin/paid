# frozen_string_literal: true

# Bounded backstop for legacy graphs and failed/partial issue synchronization.
# Normal parsing reconciles immediately; this job only re-reads persisted edges.
class DependencyCycleReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "dependency_cycle_reconciliation")

  def perform # @spec AUTO-PICK-QUEUE-014
    Account.find_each do |account|
      Issues::DependencyCycles.call(account:)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    rescue Issues::DependencyCycles::CoverageUnavailable => error
      Rails.logger.warn(message: "dependency_cycles.reconciliation_unavailable", account_id: account.id,
        error_class: error.class.name, error: error.message)
    end
  end
end
