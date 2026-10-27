# frozen_string_literal: true

module Inbox
  # Presentation state for the explicit facet-confidence evaluation workflow
  # embedded in an Action Required notification. The workflow key is a stable
  # producer contract; never infer this route by parsing operator-facing text.
  # @spec OPERATOR-INBOX-002L
  # @spec FACET-CONFIDENCE-022
  class FacetConfidenceEvaluationEscalation
    WORKFLOW = "facet_confidence_closeout_evaluation"

    def self.for(notification:, issue:, evaluation:)
      return unless notification.metadata["workflow"] == WORKFLOW
      return unless issue

      new(issue:, evaluation:)
    end

    def initialize(issue:, evaluation:)
      @issue = issue
      @evaluation = evaluation
    end

    def title = "Independent evaluation needed"

    def explanation
      return "Review each frozen test case independently, record your judgment, and freeze the completed set." unless evaluation
      return "All judgments are frozen. Review the completed evaluation report." if evaluation.frozen?
      return "Every test case has a recorded judgment. Freeze the completed set to finish the evaluation." if remaining.zero? && skipped.zero?

      "Review each frozen test case independently and record your judgment before freezing the completed set."
    end

    def action_label
      return "Start evaluation" unless evaluation
      return "Open evaluation report" if evaluation.frozen?
      return "Freeze judgments" if remaining.zero? && skipped.zero?

      "Continue judging"
    end

    def progress
      return { labeled: 0, total: nil, skipped: 0, remaining: nil } unless evaluation

      current_progress.merge(remaining: remaining)
    end

    def evaluation? = evaluation.present?
    def frozen? = evaluation&.frozen?

    attr_reader :evaluation

    private

    attr_reader :issue

    def remaining
      current = current_progress
      current[:total] - current[:labeled] - current[:skipped]
    end

    def skipped
      current_progress[:skipped]
    end

    def current_progress = @current_progress ||= evaluation.progress
  end
end
