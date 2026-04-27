# frozen_string_literal: true

module LlmOutputMetrics
  # Collects quality feedback for LLM-generated decision records.
  #
  # Signals:
  #   - record_kept (1.0 if status is still "active", 0.0 if reverted/superseded)
  #   - tag_count (0.0-1.0, based on number of meaningful tags)
  #
  # @example
  #   LlmOutputMetrics::CollectDecisionRecordFeedback.call(
  #     project: project,
  #     decision_record: decision_record
  #   )
  class CollectDecisionRecordFeedback
    # Minimum and maximum tag counts for scoring.
    # 1 tag scores low, 3+ tags scores 1.0.
    MIN_TAGS_FOR_FULL_SCORE = 3

    def self.call(...)
      new(...).call
    end

    def initialize(project:, decision_record:)
      @project = project
      @decision_record = decision_record
    end

    def call
      metric = find_metric
      return nil unless metric

      scores = {}
      feedback_metadata = {}

      collect_kept_signal(scores, feedback_metadata)
      collect_tag_count_signal(scores, feedback_metadata)

      return metric if scores.empty?

      update_metric(metric, scores, feedback_metadata)
    end

    private

    attr_reader :project, :decision_record

    def find_metric
      LlmOutputMetric.find_by(
        project: project,
        output_type: "decision_record",
        source_type: "DecisionRecord",
        source_id: decision_record.id
      )
    end

    def collect_kept_signal(scores, feedback_metadata)
      kept = decision_record.status == "active"
      scores["record_kept"] = kept ? 1.0 : 0.0
      feedback_metadata["decision_status"] = decision_record.status
    end

    def collect_tag_count_signal(scores, feedback_metadata)
      tags = Array(decision_record.tags).reject(&:blank?)
      count = tags.size
      feedback_metadata["tag_count"] = count

      scores["tag_count"] = if count >= MIN_TAGS_FOR_FULL_SCORE
        1.0
      elsif count.zero?
        0.0
      else
        (count.to_f / MIN_TAGS_FOR_FULL_SCORE).round(4)
      end
    end

    def update_metric(metric, scores, feedback_metadata)
      metric.scores = metric.scores.merge(scores)
      metric.metadata = metric.metadata.merge(
        feedback_metadata.merge("feedback_collected_at" => Time.current.iso8601)
      )
      metric.composite_score = metric.calculate_composite_score
      metric.save!
      metric
    end
  end
end
