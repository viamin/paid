# frozen_string_literal: true

# Detects goal-level failure patterns in agent runs per account and notifies.
# Accounts are processed in bounded pages: continuation arguments carry an
# immutable account-ID keyset cursor (after_account_id) and the cycle's
# captured end (through_account_id), so accounts created during a cycle are
# deferred to the next scheduled cycle and one perform stays bounded in
# duration and memory. A failed account is retried once inside the cycle and
# otherwise deferred to the next cycle.
# @spec RUN-OBSTACLE-006
class AgentRunPatternDetectorJob < ApplicationJob
  # @spec RUN-OBSTACLE-004
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  ACCOUNT_PAGE_SIZE = 2
  MAX_ACCOUNT_ATTEMPTS = 2

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "agent_run_pattern_detector"
  )

  AccountResult = Struct.new(:account_id, :pattern_count, :failed, :attempts, keyword_init: true)

  def perform(after_account_id: nil, through_account_id: nil, pending_accounts: {})
    page_started_at = monotonic_clock
    page_allocated_before = GC.stat(:total_allocated_objects)

    TenantContext.with_system_access do
      through_account_id ||= Account.maximum(:id)
      return unless through_account_id

      # Continuations always serialize string keys, but normalize so any
      # integer-keyed invocation cannot reset attempts and retry unboundedly.
      pending_accounts = pending_accounts.to_h { |id, attempts| [ id.to_i, attempts.to_i ] }
      fresh_page = pending_accounts.empty?
      page = fresh_page ? account_page(after_account_id, through_account_id) : retry_page(pending_accounts)
      results = page.map { |account| process_account(account, attempts: pending_accounts.fetch(account.id, 0)) }

      # An emptied fresh page (its accounts deleted mid-cycle) must not reset
      # the cursor: advance to the captured end instead of re-sweeping from 0.
      boundary_id = fresh_page ? (page.last&.id || through_account_id) : after_account_id
      log_page(results, page_started_at, page_allocated_before)
      continue_cycle(boundary_id, through_account_id, results)
    end
  end

  private

  def account_page(after_account_id, through_account_id)
    Account.where("accounts.id > ? AND accounts.id <= ?", after_account_id.to_i, through_account_id)
      .order(:id)
      .limit(ACCOUNT_PAGE_SIZE)
      .to_a
  end

  def retry_page(pending_accounts)
    Account.where(id: pending_accounts.keys)
      .order(:id)
      .to_a
  end

  def process_account(account, attempts:)
    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)

    patterns = AgentRunPatterns::Detect.call(account: account)
    results = build_diagnoses(account, patterns)
    AgentRunPatterns::Notify.call(
      account: account,
      patterns: patterns,
      diagnoses: results[:diagnoses],
      decisions: results[:decisions]
    )

    Rails.logger.info(
      message: "agent_run_patterns.account_completed",
      account_id: account.id,
      pattern_count: patterns.size,
      goals: patterns.map(&:goal).uniq,
      duration_ms: elapsed_ms(started_at),
      allocations: GC.stat(:total_allocated_objects) - allocated_before
    )
    AccountResult.new(account_id: account.id, pattern_count: patterns.size)
  rescue => e
    attempts += 1
    Rails.logger.warn(
      message: "agent_run_patterns.detection_failed_for_account",
      account_id: account.id,
      attempt: attempts,
      retry_exhausted: attempts >= MAX_ACCOUNT_ATTEMPTS,
      duration_ms: elapsed_ms(started_at),
      allocations: GC.stat(:total_allocated_objects) - allocated_before,
      error_class: e.class.name,
      error: e.message
    )
    AccountResult.new(account_id: account.id, pattern_count: 0, failed: true, attempts: attempts)
  end

  def continue_cycle(after_account_id, through_account_id, results)
    retries = results
      .select { |result| result.failed && result.attempts < MAX_ACCOUNT_ATTEMPTS }
      .to_h { |result| [ result.account_id.to_s, result.attempts ] }

    if retries.any?
      self.class.perform_later(after_account_id:, through_account_id:, pending_accounts: retries)
    else
      enqueue_next_page(after_account_id, through_account_id)
    end
  end

  def enqueue_next_page(after_account_id, through_account_id)
    if account_page(after_account_id, through_account_id).empty?
      Rails.logger.info(message: "agent_run_patterns.cycle_completed", through_account_id: through_account_id)
      return
    end

    self.class.perform_later(after_account_id:, through_account_id:)
  end

  # @spec RUN-OBSTACLE-003
  def build_diagnoses(account, patterns)
    remaining_budget = AgentRunPatterns::DailyDiagnosisBudget.remaining_for(account: account)

    patterns.each_with_object({ diagnoses: {}, decisions: {} }) do |pattern, result|
      allow_llm = remaining_budget.positive?
      remaining_budget -= 1 if allow_llm

      diagnosis = AgentRunPatterns::Diagnose.call(
        pattern,
        account: account,
        allow_llm: allow_llm
      )
      decision = AgentRunPatterns::RecordRemediationDecision.call(
        account: account,
        pattern: pattern,
        diagnosis: diagnosis
      )
      # A reasoned dismissal mutes re-announcement in Notify while the
      # decision record itself keeps accruing occurrences.
      next if decision.dismissed?

      result[:diagnoses][fingerprint(pattern)] = diagnosis
      result[:decisions][fingerprint(pattern)] = decision
    end
  end

  def fingerprint(pattern)
    pattern.details[:fingerprint].to_s
  end

  def log_page(results, started_at, allocated_before)
    Rails.logger.info(
      message: "agent_run_patterns.page_completed",
      account_count: results.size,
      pattern_count: results.sum(&:pattern_count),
      failed_count: results.count(&:failed),
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
