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

  good_job_control_concurrency_with(
    total_limit: 1,
    # The daily cron enqueue may overlap a currently performing batch. Keep a
    # second queue position available for that batch's cursor continuation.
    enqueue_limit: 2,
    key: "legacy_partial_closeout_reconciliation_sweep"
  )

  def perform(account_id: nil, after_id: nil, after_account_id: nil)
    TenantContext.with_system_access do
      account = account_id ? Account.active.find_by(id: account_id) : next_account(after_account_id)
      reconcile(account, after_id:, after_account_id:) if account
    end
  end

  private

  def reconcile(account, after_id:, after_account_id:)
    result = PartialCloseouts::ReconcileLegacy.call(account_id: account.id, after_id:)
    log_result(account, result, after_id:)
    enqueue_next(account, result, after_account_id:) unless result.lock_held
  rescue StandardError => e
    log_failure(account, e, after_id:)
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
