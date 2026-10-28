# frozen_string_literal: true

module FacetConfidence
  # Typed adapter between a partial-closeout notification and the existing
  # closeout evaluation. Untyped notifications deliberately return nil.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredEvaluation
    WORKFLOW = "facet_confidence_closeout_evaluation"

    Result = Data.define(:issue, :evaluation, :progress) do
      def recorded = progress[:labeled]
      def remaining = progress[:total] - progress[:labeled]

      def action_label
        return "Start evaluation" unless evaluation
        return "View evaluation report" if evaluation.frozen?
        return "Freeze judgments" if remaining.zero?

        recorded.zero? ? "Resume evaluation" : "Continue judging"
      end
    end

    def self.call(notification)
      return unless notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE
      return unless notification.metadata["workflow"] == WORKFLOW
      return unless notification.subject.is_a?(Issue)

      issue = notification.subject
      evaluation = issue.facet_confidence_evaluations.latest_first.first
      Result.new(issue:, evaluation:, progress: evaluation&.progress || empty_progress)
    end

    def self.empty_progress = { total: 0, labeled: 0, skipped: 0 }
    private_class_method :empty_progress
  end
end
