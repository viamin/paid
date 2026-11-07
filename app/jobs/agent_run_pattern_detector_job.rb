# frozen_string_literal: true

# Scheduled detection of goal-level failure patterns across the account
# fleet. Each perform processes a bounded batch of accounts, then enqueues a
# cursor-carrying continuation until the cycle reaches the end captured at
# cycle start, so a single perform's duration and memory stay bounded as the
# fleet grows (one account can spend minutes in LLM diagnosis).
class AgentRunPatternDetectorJob < ApplicationJob
  # @spec RUN-OBSTACLE-004
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  # @spec RUN-OBSTACLE-006
  ACCOUNTS_PER_PERFORM = 2

  # @spec RUN-OBSTACLE-006
  good_job_control_concurrency_with(
    # enqueue_limit excludes the currently performing (locked) job, so a
    # batch can enqueue its own continuation; it still discards a scheduled
    # tick's fresh enqueue while a continuation sits queued, preventing
    # duplicate chains. perform_limit keeps two cycles from overlapping.
    # total_limit would count the performing job at enqueue time and
    # deadlock the chain's own continuation.
    enqueue_limit: 1,
    perform_limit: 1,
    key: "agent_run_pattern_detector"
  )

  def perform(after_account_id: nil, cycle_last_account_id: nil)
    started_at = monotonic_clock

    TenantContext.with_system_access do
      cycle_end = cycle_last_account_id || Account.maximum(:id)
      batch = account_batch(after_account_id, cycle_end)
      stats = process_accounts(batch)
      advance_cycle(batch, cycle_end, stats.merge(duration_ms: elapsed_ms(started_at)))
    end
  end

  private

  def account_batch(after_account_id, cycle_end)
    return [] unless cycle_end

    scope = Account.where("id <= ?", cycle_end).order(:id)
    scope = scope.where("id > ?", after_account_id) if after_account_id
    # Fetch one extra row to know whether a continuation is owed without a
    # separate count query.
    scope.limit(ACCOUNTS_PER_PERFORM + 1).to_a
  end

  def process_accounts(batch)
    batch.first(ACCOUNTS_PER_PERFORM).each_with_object(accounts_processed: 0, accounts_failed: 0, total_patterns: 0) do |account, stats|
      outcome = process_account(account)
      stats[:accounts_processed] += 1
      stats[:total_patterns] += outcome[:pattern_count]
      stats[:accounts_failed] += 1 if outcome[:failed]
    end
  end

  # @spec RUN-OBSTACLE-007
  def process_account(account)
    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)
    patterns = AgentRunPatterns::Detect.call(account: account)
    notify_for(account, patterns)
    log_account_processed(account, patterns, started_at, allocated_before)
    { failed: false, pattern_count: patterns.size }
  rescue => e
    log_account_failure(account, e, started_at, allocated_before)
    { failed: true, pattern_count: 0 }
  end

  def notify_for(account, patterns)
    results = build_diagnoses(account, patterns)
    AgentRunPatterns::Notify.call(
      account: account,
      patterns: patterns,
      diagnoses: results[:diagnoses],
      decisions: results[:decisions]
    )
  end

  def advance_cycle(batch, cycle_end, stats)
    if batch.size > ACCOUNTS_PER_PERFORM
      self.class.perform_later(
        after_account_id: batch[ACCOUNTS_PER_PERFORM - 1].id,
        cycle_last_account_id: cycle_end
      )
      Rails.logger.info(message: "agent_run_patterns.batch_completed", **stats, continuation_enqueued: true)
    else
      Rails.logger.info(message: "agent_run_patterns.detection_completed", **stats, cycle_completed: true)
    end
  end

  def log_account_processed(account, patterns, started_at, allocated_before)
    Rails.logger.info(
      message: "agent_run_patterns.account_processed",
      account_id: account.id,
      pattern_count: patterns.size,
      goals: patterns.map(&:goal).uniq,
      duration_ms: elapsed_ms(started_at),
      allocated_objects: GC.stat(:total_allocated_objects) - allocated_before
    )
  end

  def log_account_failure(account, error, started_at, allocated_before)
    Rails.logger.warn(
      message: "agent_run_patterns.detection_failed_for_account",
      account_id: account.id,
      error_class: error.class.name,
      error: error.message,
      duration_ms: elapsed_ms(started_at),
      allocated_objects: GC.stat(:total_allocated_objects) - allocated_before
    )
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

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
