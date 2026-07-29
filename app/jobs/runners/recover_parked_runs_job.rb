# frozen_string_literal: true

module Runners
  # Re-evaluates a user's parked `rate_limited` runs when runner capacity
  # changes (a runner is created, re-enabled, or undiscarded).
  #
  # Parked runs are normally recovered on a *time* trigger — `StaleRunDetectorJob`
  # re-queues them once `rate_limited_until` elapses. But when new runner
  # capacity appears (e.g. a fallback runner is added while the only compatible
  # runner was rate-limited), nothing woke those runs: they stayed parked until
  # the original runner's rate-limit window cleared, even though a fallback could
  # have served them immediately. This job closes that gap by making the user's
  # parked runs due now so `StaleRunDetectorJob` re-queues them on its next tick.
  #
  # If a parked run's runner is still genuinely unavailable, the re-dispatch
  # simply re-parks it (with a fresh reset) — so this never makes things worse,
  # it only accelerates re-evaluation when capacity may have changed.
  class RecoverParkedRunsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: ->(user_id) { "runners_recover_parked_runs/#{user_id}" }
    )

    def perform(user_id)
      TenantContext.with_system_access do
        account = User.find_by(id: user_id)&.account
        return unless account

        account_project_ids = Project.where(account_id: account.id).select(:id)
        parked = AgentRun.rate_limited
          .where.not(issue_id: nil)
          .where("agent_runs.rate_limited_until > ?", Time.current)
          .where(project_id: account_project_ids)

        count = parked.update_all(rate_limited_until: 1.minute.ago, updated_at: Time.current)
        return if count.zero?

        StaleRunDetectorJob.perform_later
        Rails.logger.info(
          message: "runners.recover_parked_runs",
          user_id: user_id,
          account_id: account.id,
          recovered_runs: count
        )
      end
    end
  end
end
