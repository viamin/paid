# frozen_string_literal: true

# Detects recurring agent-run obstacles per account and records reviewable
# remediation proposals. The fleet sweep runs as a bounded continuation chain
# because detection and diagnosis can include external LLM work: each perform
# sweeps at most ACCOUNTS_PER_PAGE accounts, and GoodJob persists the keyset
# cursor, captured cycle end, and accumulated pattern count in each
# continuation's arguments, so one perform's duration and memory stay flat as
# the fleet grows. The cron entry
# enqueues only this cursor-less starter; a starter that finds an unfinished
# continuation skips itself, and the shared concurrency key rejects duplicate
# enqueues, so chains never overlap.
# @spec RUN-OBSTACLE-006
# @spec RUN-OBSTACLE-007
class AgentRunPatternDetectorJob < ApplicationJob
  # @spec RUN-OBSTACLE-004
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  ACCOUNTS_PER_PAGE = 3

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "agent_run_pattern_detector"
  )

  # One page of the detection cycle: the swept accounts, the keyset cursor the
  # page started from, the captured cycle end, and the patterns found.
  PageResult = Data.define(:accounts, :after_account_id, :through_account_id, :total_patterns)

  # Wall-clock and allocation sampling for one page or account sweep.
  SweepUsage = Struct.new(:started_at, :allocated_before) do
    def self.start
      new(Process.clock_gettime(Process::CLOCK_MONOTONIC), GC.stat(:total_allocated_objects))
    end

    def duration_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end

    def allocations
      GC.stat(:total_allocated_objects) - allocated_before
    end
  end

  def perform(after_account_id: nil, through_account_id: nil, total_patterns: 0)
    return if fresh_cycle_start?(after_account_id) && continuation_pending?

    page_usage = SweepUsage.start
    result = TenantContext.with_system_access do
      sweep_page(after_account_id: after_account_id, through_account_id: through_account_id)
    end
    return unless result

    log_page(result, page_usage)
    cycle_total_patterns = total_patterns + result.total_patterns

    if continuation?(result)
      AgentRunPatternDetectorContinuationJob.perform_later(
        after_account_id: result.accounts.last.id,
        through_account_id: result.through_account_id,
        total_patterns: cycle_total_patterns
      )
    else
      log_cycle_completed(result, cycle_total_patterns)
    end
  end

  private

  def sweep_page(after_account_id:, through_account_id:)
    through = through_account_id || Account.maximum(:id)
    return unless through

    accounts = Account.where("id > ? AND id <= ?", after_account_id.to_i, through)
      .order(:id)
      .limit(ACCOUNTS_PER_PAGE)
      .to_a

    PageResult.new(
      accounts: accounts,
      after_account_id: after_account_id,
      through_account_id: through,
      total_patterns: accounts.sum { |account| sweep_account(account) }
    )
  end

  # A full page continues only while accounts remain inside the captured
  # cycle end, so the chain terminates instead of enqueuing an empty no-op
  # page at the fleet boundary.
  def continuation?(result)
    result.accounts.size == ACCOUNTS_PER_PAGE &&
      Account.where("id > ? AND id <= ?", result.accounts.last.id, result.through_account_id).exists?
  end

  def fresh_cycle_start?(after_account_id)
    after_account_id.nil?
  end

  # A duplicate cron start that slipped past the enqueue limit while the
  # previous page was still performing must not sweep a second, overlapping
  # chain; the pending continuation already owns the fleet.
  # @spec RUN-OBSTACLE-007
  def continuation_pending?
    GoodJob::Job.unfinished.where(job_class: AgentRunPatternDetectorContinuationJob.name).exists?
  end

  # One account failure is observable and skipped; idempotent detection,
  # daily diagnosis budget, fingerprint dedupe, and notification resolution
  # make the next cycle's retry safe.
  # @spec RUN-OBSTACLE-007
  def sweep_account(account)
    usage = SweepUsage.start

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
      duration_ms: usage.duration_ms,
      allocations: usage.allocations
    )
    patterns.size
  rescue => e
    Rails.logger.warn(
      message: "agent_run_patterns.detection_failed_for_account",
      account_id: account.id,
      error_class: e.class.name,
      error: e.message,
      duration_ms: usage.duration_ms,
      allocations: usage.allocations
    )
    0
  end

  def log_page(result, usage)
    Rails.logger.info(
      message: "agent_run_patterns.detection_page_completed",
      account_count: result.accounts.size,
      total_patterns: result.total_patterns,
      after_account_id: result.after_account_id,
      through_account_id: result.through_account_id,
      duration_ms: usage.duration_ms,
      allocations: usage.allocations,
      peak_rss_kb: peak_rss_kb
    )
  end

  def log_cycle_completed(result, total_patterns)
    Rails.logger.info(
      message: "agent_run_patterns.detection_cycle_completed",
      through_account_id: result.through_account_id,
      total_patterns:
    )
  end

  def peak_rss_kb
    File.foreach("/proc/self/status") do |line|
      return line.split[1].to_i if line.start_with?("VmHWM:")
    end
    nil
  rescue Errno::ENOENT
    nil
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
end
