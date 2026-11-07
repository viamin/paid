# frozen_string_literal: true

# Frequent, bounded sweep keeping the partial-closeout stall projection
# current (RDR-081). One account per perform: resolves its flag-enabled
# projects, finds those due — no successful checkpoint yet, or an
# admission-relevant input newer than the checkpoint's watermark — and
# enqueues one recomputation job per due project, then chains to the next
# account. A missed trigger or interrupted initial backfill therefore
# self-heals on the next pass instead of stranding a stall.
# @spec PARTIAL-CLOSEOUT-042
class StalledCloseoutProjectionSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: "stalled_closeout_projection_sweep"
  )

  def perform(after_account_id: nil)
    TenantContext.with_system_access do
      scope = Account.active.order(:id)
      scope = scope.where("id > ?", after_account_id) if after_account_id
      account = scope.first
      return unless account

      sweep(account)
      self.class.perform_later(after_account_id: account.id)
    end
  end

  private

  def sweep(account)
    due = Issues::StalledCloseoutProjection.due_projects(account)
    due.each { |project| RecomputeStalledCloseoutProjectionJob.perform_later(project.id) }

    Rails.logger.info(
      message: "issues.stall_projection_sweep_completed",
      account_id: account.id,
      due_projects: due.size
    )
  rescue StandardError => error
    # Advance past this account so one account's persistently failing sweep
    # cannot starve every account after it; the next cron pass retries.
    Rails.logger.error(
      message: "issues.stall_projection_sweep_failed",
      account_id: account.id,
      error_class: error.class.name,
      error: error.message
    )
  end
end
