# frozen_string_literal: true

# Collects feedback for LLM output metrics that are not tied to agent run
# lifecycle events (e.g., decision records). Runs periodically via GoodJob
# cron to update quality scores on metrics whose initial scores are empty.
#
# PR description and issue title feedback are collected via
# HumanFeedbackCollectionJob; this job covers the remaining output types.
class LlmOutputMetricFeedbackCollectionJob < ApplicationJob
  queue_as :low_priority

  # Only process metrics created within this window.
  LOOKBACK_WINDOW = 7.days

  def perform
    LlmOutputMetric
      .where(output_type: "decision_record")
      .where(created_at: LOOKBACK_WINDOW.ago..)
      .where(composite_score: nil)
      .find_each do |metric|
        collect_decision_record_feedback(metric)
      end
  end

  private

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
