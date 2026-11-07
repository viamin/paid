# frozen_string_literal: true

# Bounded backstop for legacy graphs and failed/partial issue synchronization.
# Normal parsing reconciles immediately; this job only re-reads persisted edges.
# Continuations retain a captured account-ID boundary, so a growing fleet does
# not shift a page or extend the current cycle indefinitely.
class DependencyCycleReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  ACCOUNT_PAGE_SIZE = 2
  UNAVAILABLE_RETRY_BASE_DELAY = 1.minute
  UNAVAILABLE_RETRY_MAX_DELAY = 10.minutes

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: "dependency_cycle_reconciliation"
  )

  # @spec AUTO-PICK-QUEUE-014
  def perform(after_account_id: nil, through_account_id: nil, unavailable_retries: 0)
    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)
    through_account_id ||= Account.maximum(:id)
    return unless through_account_id

    accounts = account_page(after_account_id, through_account_id)
    last_successful_account_id, reconciled_count, unavailable_count = reconcile_page(accounts)
    log_page(started_at, allocated_before, accounts, after_account_id, through_account_id, reconciled_count, unavailable_count)
    return unless next_page?(last_successful_account_id, through_account_id)

    enqueue_continuation(last_successful_account_id, through_account_id,
      unavailable_retries: unavailable_count.positive? ? unavailable_retries + 1 : 0)
  end

  private

  def account_page(after_account_id, through_account_id)
    Account.where("accounts.id > ? AND accounts.id <= ?", after_account_id.to_i, through_account_id)
      .order(:id)
      .limit(ACCOUNT_PAGE_SIZE)
      .to_a
  end

  def reconcile_page(accounts)
    last_successful_account_id = nil
    reconciled_count = 0
    unavailable_count = 0

    accounts.each do |account|
      Issues::DependencyCycles.call(account:)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
      last_successful_account_id = account.id
      reconciled_count += 1
    rescue Issues::DependencyCycles::CoverageUnavailable => error
      unavailable_count += 1
      Rails.logger.warn(message: "dependency_cycles.reconciliation_unavailable", account_id: account.id,
        error_class: error.class.name, error: error.message)
      break
    end

    [ last_successful_account_id, reconciled_count, unavailable_count ]
  end

  def next_page?(after_account_id, through_account_id)
    Account.where("accounts.id > ? AND accounts.id <= ?", after_account_id.to_i, through_account_id).exists?
  end

  # A page stopped by an unavailable account retries the same cursor after a
  # backed-off delay (1m doubling to a 10m cap): an immediate continuation
  # would hot-loop the maintenance worker on the failing account until the
  # coverage outage resolves. Fully successful pages continue immediately and
  # reset the backoff.
  def enqueue_continuation(after_account_id, through_account_id, unavailable_retries:)
    if unavailable_retries.zero?
      self.class.perform_later(after_account_id:, through_account_id:)
    else
      self.class.set(wait: unavailable_retry_delay(unavailable_retries))
        .perform_later(after_account_id:, through_account_id:, unavailable_retries:)
    end
  end

  def unavailable_retry_delay(unavailable_retries)
    [ UNAVAILABLE_RETRY_BASE_DELAY * (2**(unavailable_retries - 1)), UNAVAILABLE_RETRY_MAX_DELAY ].min
  end

  def log_page(started_at, allocated_before, accounts, after_account_id, through_account_id, reconciled_count, unavailable_count)
    Rails.logger.info(
      message: "dependency_cycles.reconciliation_page_completed",
      account_count: accounts.size,
      reconciled_count:,
      unavailable_count:,
      after_account_id:,
      through_account_id:,
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
