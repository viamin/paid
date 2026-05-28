# frozen_string_literal: true

class AgentRunPatternDetectorJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "agent_run_pattern_detector"
  )

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    total_patterns = 0

    TenantContext.with_system_access do
      Account.find_each do |account|
        patterns = AgentRunPatterns::Detect.call(account: account)
        total_patterns += patterns.size

        results = build_diagnoses(account, patterns)
        AgentRunPatterns::Notify.call(
          account: account,
          patterns: patterns,
          diagnoses: results[:diagnoses],
          decisions: results[:decisions]
        )

        next if patterns.empty?

        Rails.logger.info(
          message: "agent_run_patterns.patterns_detected",
          account_id: account.id,
          pattern_count: patterns.size,
          goals: patterns.map(&:goal).uniq
        )
      rescue => e
        Rails.logger.warn(
          message: "agent_run_patterns.detection_failed_for_account",
          account_id: account.id,
          error_class: e.class.name,
          error: e.message
        )
      end
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "agent_run_patterns.detection_completed",
      total_patterns: total_patterns,
      duration_ms: duration_ms
    )
  end

  private

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
      decision = AgentRunPatterns::AutoApply.call(
        decision: decision,
        pattern: pattern
      )

      result[:diagnoses][fingerprint(pattern)] = diagnosis
      result[:decisions][fingerprint(pattern)] = decision
    end
  end

  def fingerprint(pattern)
    pattern.details[:fingerprint].to_s
  end
end
