# frozen_string_literal: true

# Bounded backstop for legacy graphs and failed/partial issue synchronization.
# Normal parsing reconciles immediately; this job only re-reads persisted edges.
#
# The sweep is paged. One execution reconciles a bounded number of accounts and
# hands the next page a stable account-id cursor plus the cycle's captured end
# (the highest account id present when the cycle started). The cursor advances
# monotonically, so a cycle reconciles each account at most once and never
# skips one, and the captured end keeps the cycle's membership stable while
# accounts are created. The cycle stops at its captured end; the next cron
# tick captures a new end, which is where accounts created during the cycle
# enter.
# @spec AUTO-PICK-QUEUE-014
# @spec AUTO-PICK-QUEUE-023
class DependencyCycleReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  # Accounts one execution reconciles. The account fleet grows, so a single
  # execution stays bounded instead of traversing every account.
  ACCOUNT_PAGE_SIZE = 5
  # Attempts one account gets before the cycle moves past it. The retry keeps a
  # transient failure from skipping the account; the bound keeps a permanently
  # failing account from stalling the cycle.
  MAX_ACCOUNT_ATTEMPTS = 3

  queue_as :maintenance

  good_job_control_concurrency_with(
    # A page enqueues its continuation while it is still performing, so the
    # queued continuation needs an enqueue slot beside the cron tick.
    enqueue_limit: 2,
    perform_limit: 1,
    key: "dependency_cycle_reconciliation"
  )

  PageOutcome = Data.define(:cursor, :attempts, :page_size, :reconciled, :unavailable, :failed)

  # @spec AUTO-PICK-QUEUE-014
  # @spec AUTO-PICK-QUEUE-023
  def perform(after_account_id: nil, through_account_id: nil, attempts: 0)
    return if cycle_already_running?(through_account_id)

    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)
    through_account_id ||= Account.maximum(:id)
    return unless through_account_id

    page = account_page(after_account_id, through_account_id)
    outcome = reconcile_page(page, after_account_id:, attempts:)
    log_page(started_at, allocated_before, outcome, through_account_id)
    enqueue_next_page(outcome, through_account_id)
  end

  private

  # A cron tick must not open a second cycle while the running cycle's next
  # page is still queued: two cycles would reconcile the same accounts twice.
  # Only pages that have not started yet count, so a job whose worker died
  # mid-page cannot stall the sweep forever.
  def cycle_already_running?(through_account_id)
    return false if through_account_id
    return false unless pending_pages.any?

    Rails.logger.info(message: "dependency_cycles.reconciliation_cycle_in_flight")
    true
  end

  def pending_pages
    GoodJob::Job.unfinished.where(performed_at: nil, job_class: self.class.name)
      .where.not(active_job_id: job_id)
  end

  def account_page(after_account_id, through_account_id)
    Account.where(id: (after_account_id.to_i + 1)..through_account_id).order(:id).limit(ACCOUNT_PAGE_SIZE).to_a
  end

  # Reconciles the page in account order and stops at the first account that
  # fails, so the cursor never advances past an account the sweep has not
  # reconciled. The next page retries that account.
  def reconcile_page(page, after_account_id:, attempts:)
    cursor = after_account_id
    attempt = attempts
    reconciled = 0
    unavailable = 0
    failed = 0

    page.each do |account|
      result = reconcile_account(account)
      if result == :failed
        failed += 1
        attempt += 1
        break if attempt < MAX_ACCOUNT_ATTEMPTS

        Rails.logger.error(message: "dependency_cycles.reconciliation_retries_exhausted",
          account_id: account.id, attempts: attempt)
      elsif result == :unavailable
        unavailable += 1
      else
        reconciled += 1
      end
      cursor = account.id
      attempt = 0
    end

    PageOutcome.new(cursor:, attempts: attempt, page_size: page.size, reconciled:, unavailable:, failed:)
  end

  def reconcile_account(account)
    Issues::DependencyCycles.call(account:)
    Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    :reconciled
  rescue Issues::DependencyCycles::CoverageUnavailable => error
    Rails.logger.warn(message: "dependency_cycles.reconciliation_unavailable", account_id: account.id,
      error_class: error.class.name, error: error.message)
    :unavailable
  rescue StandardError => error
    Rails.logger.error(message: "dependency_cycles.reconciliation_failed", account_id: account.id,
      error_class: error.class.name, error: error.message)
    :failed
  end

  def enqueue_next_page(outcome, through_account_id)
    return unless more_accounts?(outcome.cursor, through_account_id)

    self.class.perform_later(
      after_account_id: outcome.cursor, through_account_id:, attempts: outcome.attempts
    )
  end

  def more_accounts?(cursor, through_account_id)
    Account.where(id: (cursor.to_i + 1)..through_account_id).exists?
  end

  def log_page(started_at, allocated_before, outcome, through_account_id)
    Rails.logger.info(
      message: "dependency_cycles.reconciliation_page_completed",
      account_count: outcome.page_size,
      reconciled_count: outcome.reconciled,
      unavailable_count: outcome.unavailable,
      failed_count: outcome.failed,
      cursor_account_id: outcome.cursor,
      cycle_end_account_id: through_account_id,
      duration_ms: elapsed_ms(started_at),
      allocations: GC.stat(:total_allocated_objects) - allocated_before
    )
  end

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_clock - started_at) * 1000).round
  end
end
