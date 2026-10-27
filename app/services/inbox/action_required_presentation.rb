# frozen_string_literal: true

module Inbox
  # Translates structured Action Required workflows into operator-facing copy.
  # Notifications without a recognized workflow deliberately return nil so the
  # generic notification detail remains the safe fallback.
  # @spec OPERATOR-INBOX-002L
  class ActionRequiredPresentation
    FACET_CONFIDENCE_EVALUATION = "facet_confidence_evaluation"

    Result = Data.define(:title, :explanation, :action_label, :evaluation, :progress)

    def self.for(notification) = new(notification).call

    def initialize(notification) = @notification = notification

    def call
      return unless facet_confidence_evaluation?

      evaluation = latest_evaluation
      Result.new(title: "Human evaluation needed", explanation: explanation(evaluation),
        action_label: action_label(evaluation), evaluation:, progress: evaluation&.progress)
    end

    private

    def facet_confidence_evaluation?
      notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE &&
        notification.metadata["workflow"] == FACET_CONFIDENCE_EVALUATION && notification.subject.is_a?(Issue)
    end

    def latest_evaluation = notification.subject.facet_confidence_evaluations.latest_first.first

    def explanation(evaluation)
      return "This closeout is waiting for an independent human review. Start the evaluation, judge every test case, then freeze the completed set." unless evaluation
      return "All judgments are recorded. Freeze the completed set to finish this evaluation." if remaining(evaluation).zero?

      "This closeout is waiting for an independent human review. Record a judgment for each remaining test case, then freeze the completed set."
    end

    def action_label(evaluation)
      return "Start evaluation" unless evaluation
      return "View evaluation" if evaluation.frozen?
      return "Freeze judgments" if remaining(evaluation).zero?

      "Continue judging"
    end

    def remaining(evaluation) = evaluation.progress[:total] - evaluation.progress[:labeled]

    attr_reader :notification
  end
end
