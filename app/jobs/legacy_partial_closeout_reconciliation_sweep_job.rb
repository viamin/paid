# frozen_string_literal: true

# Daily, bounded recovery for closeouts created before the Temporal
# reconciliation patch. GoodJob persists the account and run cursors in each
# follow-up job's arguments, so the chain resumes the next bounded window
# instead of repeatedly spending the batch on already reconciled history.
# ReconcileLegacy owns the account advisory lock and all continuation
# admission; this job only schedules and records the sweep.
# @spec PARTIAL-CLOSEOUT-025
class LegacyPartialCloseoutReconciliationSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  # An operator/rake `ReconcileLegacy` call for the same account holds the
  # advisory lock for the duration of a batch, not forever — retrying soon
  # finds it released. A short, fixed delay avoids hot-looping the queue
  # while the other caller finishes.
  LOCK_CONTENTION_RETRY_DELAY = 5.minutes

  good_job_control_concurrency_with(
    # A full batch enqueues its cursor continuation while it is still
    # performing. Keep that queued continuation separate from the single
    # performing job; total_limit would count the current job at enqueue time.
    enqueue_limit: 2,
    perform_limit: 1,
    key: "legacy_partial_closeout_reconciliation_sweep"
  )

  def perform(account_id: nil, after_id: nil, after_account_id: nil)
    TenantContext.with_system_access do
      account = account_id ? Account.active.find_by(id: account_id) : next_account(after_account_id)
      if account
        reconcile(account, after_id:, after_account_id:)
      elsif account_id
        # account_id resolved but the account is no longer active (suspended/
        # deactivated mid-chain) - advance past it instead of dropping the
        # rest of the fleet's sweep for the day.
        self.class.perform_later(after_account_id: account_id)
      end
    end
  end

  private

  def reconcile(account, after_id:, after_account_id:)
    result = PartialCloseouts::ReconcileLegacy.call(account_id: account.id, after_id:)
    log_result(account, result, after_id:)
    if result.lock_held
      retry_after_lock_contention(account, result, after_account_id:)
    else
      enqueue_next(account, result, after_account_id:)
    end
  rescue StandardError => e
    log_failure(account, e, after_id:)
    # Advance past this account on failure (mirroring enqueue_next/
    # retry_after_lock_contention) so one account's persistently failing
    # reconcile can't starve every account after it for the rest of the day.
    self.class.perform_later(after_account_id: account.id)
  end

  # `ReconcileLegacy` returns `next_cursor: after_id` unchanged on lock
  # contention (app/services/partial_closeouts/reconcile_legacy.rb), so
  # retrying with it resumes the same account and cursor instead of
  # dropping the continuation and re-scanning from the start of the
  # account's history on the next cron run.
  def retry_after_lock_contention(account, result, after_account_id:)
    self.class.set(wait: LOCK_CONTENTION_RETRY_DELAY).perform_later(
      account_id: account.id, after_id: result.next_cursor, after_account_id:
    )
  end

  def next_account(after_account_id)
    scope = Account.active.order(:id)
    scope = scope.where("id > ?", after_account_id) if after_account_id
    scope.first
  end

  def enqueue_next(account, result, after_account_id:)
    if result.scanned == PartialCloseouts::ReconcileLegacy::DEFAULT_BATCH_SIZE && result.next_cursor
      self.class.perform_later(account_id: account.id, after_id: result.next_cursor, after_account_id:)
    else
      self.class.perform_later(after_account_id: account.id)
    end
  end

  def log_result(account, result, after_id:)
    Rails.logger.info(
      message: "partial_closeouts.legacy_reconcile_sweep_completed",
      account_id: account.id,
      after_id:,
      **result.to_h
    )
  end

  def log_failure(account, error, after_id:)
    Rails.logger.error(
      message: "partial_closeouts.legacy_reconcile_sweep_failed",
      account_id: account.id,
      after_id:,
      error_class: error.class.name,
      error: error.message
    )
  end
end
