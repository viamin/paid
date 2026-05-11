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

    Account.find_each do |account|
      patterns = AgentRunPatterns::Detect.call(account: account)
      next if patterns.empty?

      total_patterns += patterns.size

      diagnoses = build_diagnoses(patterns)
      AgentRunPatterns::Notify.call(account: account, patterns: patterns, diagnoses: diagnoses)

      Rails.logger.info(
        message: "agent_run_patterns.patterns_detected",
        account_id: account.id,
        pattern_count: patterns.size,
        goals: patterns.map(&:goal).uniq
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "agent_run_patterns.detection_completed",
      total_patterns: total_patterns,
      duration_ms: duration_ms
    )
  end

  private

  def build_diagnoses(patterns)
    patterns.each_with_object({}) do |pattern, hash|
      hash[pattern.goal] ||= AgentRunPatterns::Diagnose.call(pattern)
    end
  end
end
