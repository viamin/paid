# frozen_string_literal: true

# Collects feedback for LLM output metrics that are not tied to agent run
# lifecycle events (e.g., decision records). Runs periodically via GoodJob
# cron to update quality scores on metrics whose initial scores are empty or
# stale. Decision records can change status (active -> superseded/reverted) and
# gain tags after initial scoring, so we re-poll recent metrics rather than
# gating on composite_score being nil.
#
# PR description and issue title feedback are collected via
# HumanFeedbackCollectionJob; this job covers the remaining output types.
class LlmOutputMetricFeedbackCollectionJob < ApplicationJob
  queue_as :low_priority

  # Only process metrics created within this window.
  LOOKBACK_WINDOW = 7.days

  # Minimum interval between feedback re-collections for a single metric.
  FRESHNESS_INTERVAL = 24.hours

  def perform
    LlmOutputMetric
      .where(output_type: "decision_record")
      .where(created_at: LOOKBACK_WINDOW.ago..)
      .find_each do |metric|
        next if recently_collected?(metric)

        collect_decision_record_feedback(metric)
      end
  end

  private

  def recently_collected?(metric)
    collected_at = metric.metadata&.dig("feedback_collected_at")
    return false unless collected_at

    Time.zone.parse(collected_at) > FRESHNESS_INTERVAL.ago
  rescue ArgumentError
    false
  end

  def collect_decision_record_feedback(metric)
    record = DecisionRecord.find_by(id: metric.source_id)
    return unless record

    LlmOutputMetrics::CollectDecisionRecordFeedback.call(
      project: metric.project,
      decision_record: record
    )
  rescue StandardError => e
    Rails.logger.warn(
      message: "llm_output_metrics.decision_record_feedback_failed",
      llm_output_metric_id: metric.id,
      error: e.message
    )
  end
end
