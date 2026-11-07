# frozen_string_literal: true

# Bounded backstop for legacy graphs and failed/partial issue synchronization.
# Normal parsing reconciles immediately; this job only re-reads persisted edges.
#
# A growing account fleet makes one unbounded perform too broad (#4898), so
# this job pages through accounts with an immutable-ID cursor, mirroring
# AutoPickEligibilitySweepJob's durable-continuation shape: a page is bounded
# by a cycle-start snapshot of the max account id, a failed account retries
# from its own cursor without blocking the rest of the page, and an account
# created mid-cycle is deferred to the next cron tick rather than extending
# the current cycle.
class DependencyCycleReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  AccountResult = Struct.new(:account_id, :succeeded, :attempts, keyword_init: true)

  queue_as :maintenance

  PAGE_SIZE = 25
  MAX_ACCOUNT_PAGE_ATTEMPTS = 2

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "dependency_cycle_reconciliation")

  # @spec AUTO-PICK-QUEUE-014
  def perform(after_account_id: nil, through_account_id: nil, page_after_account_id: nil, pending_accounts: {})
    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)
    through_account_id ||= Account.maximum(:id)
    return unless through_account_id

    page = pending_accounts.presence || fresh_account_page(after_account_id, through_account_id)
    page_after_account_id ||= cursor_value(page.values.last, :account_id) if page.present?
    results = reconcile_page(page)
    log_page(started_at, allocated_before, page.size, results)

    retry_page = results.filter_map { |result| retry_cursor(result) }.index_by { |cursor| cursor_value(cursor, :account_id).to_s }
    if retry_page.any?
      self.class.perform_later(
        after_account_id: page_after_account_id,
        through_account_id:,
        page_after_account_id:,
        pending_accounts: retry_page
      )
      return
    end

    enqueue_next_page(page_after_account_id, through_account_id) if page.present?
  end

  private

  def fresh_account_page(after_account_id, through_account_id)
    account_page(after_account_id, through_account_id).index_with { |account| { account_id: account.id, attempts: 0 } }
  end

  def account_page(after_account_id, through_account_id)
    Account.where("accounts.id > ? AND accounts.id <= ?", after_account_id.to_i, through_account_id)
      .order(:id)
      .limit(PAGE_SIZE)
      .to_a
  end

  def reconcile_page(page)
    accounts = Account.where(id: page.values.map { |cursor| cursor_value(cursor, :account_id) }).index_by(&:id)
    page.values.map { |cursor| reconcile_account(accounts[cursor_value(cursor, :account_id)], cursor) }
  end

  def reconcile_account(account, cursor)
    account_id = cursor_value(cursor, :account_id)
    return AccountResult.new(account_id:, succeeded: true) unless account

    Issues::DependencyCycles.call(account:)
    Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    AccountResult.new(account_id: account.id, succeeded: true)
  rescue Issues::DependencyCycles::CoverageUnavailable => error
    log_account_failure(:warn, "dependency_cycles.reconciliation_unavailable", account_id, error)
    AccountResult.new(account_id:, succeeded: false, attempts: cursor_value(cursor, :attempts).to_i + 1)
  rescue StandardError => error
    log_account_failure(:error, "dependency_cycle_reconciliation.account_failed", account_id, error)
    AccountResult.new(account_id:, succeeded: false, attempts: cursor_value(cursor, :attempts).to_i + 1)
  end

  def log_account_failure(level, message, account_id, error)
    Rails.logger.public_send(level, message: message, account_id: account_id,
      error_class: error.class.name, error: error.message)
  end

  def retry_cursor(result)
    return nil if result.succeeded
    return nil if result.attempts.to_i >= MAX_ACCOUNT_PAGE_ATTEMPTS

    { account_id: result.account_id, attempts: result.attempts }
  end

  def enqueue_next_page(after_account_id, through_account_id)
    return if account_page(after_account_id, through_account_id).empty?

    self.class.perform_later(after_account_id:, through_account_id:)
  end

  def cursor_value(cursor, key)
    cursor[key] || cursor[key.to_s]
  end

  def log_page(started_at, allocated_before, account_count, results)
    Rails.logger.info(
      message: "dependency_cycle_reconciliation.page_completed",
      account_count:,
      succeeded_count: results.count(&:succeeded),
      failed_count: results.count { |result| !result.succeeded },
      duration_ms: elapsed_ms(started_at),
      allocations: GC.stat(:total_allocated_objects) - allocated_before,
      peak_rss_kb: peak_rss_kb
    )
  end

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_clock - started_at) * 1000).round
  end

  def peak_rss_kb
    File.foreach("/proc/self/status") do |line|
      return line.split.last.to_i if line.start_with?("VmHWM:")
    end
    nil
  rescue Errno::ENOENT
    nil
  end
end
