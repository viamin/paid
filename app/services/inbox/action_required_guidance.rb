# frozen_string_literal: true

module Inbox
  # Translates explicitly typed Action Required workflows into the action the
  # operator can take in Paid. Untyped notifications retain their persisted
  # description and remediation guidance in the generic Inbox presentation.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredGuidance
    FACET_CONFIDENCE_CLOSEOUT_EVALUATION = "facet_confidence_closeout_evaluation"

    Result = Data.define(:type, :evaluation) do
      def facet_confidence_closeout_evaluation?
        type == FACET_CONFIDENCE_CLOSEOUT_EVALUATION
      end

      def title
        "Complete the closeout evaluation"
      end

      def summary
        "This work is blocked until a maintainer independently reviews every test case, records a judgment, and freezes the completed set."
      end

      def primary_action
        return "Start evaluation" unless evaluation
        return "View evaluation report" if evaluation.frozen?
        return "Freeze judgments" if ready_to_freeze?

        "Continue judging"
      end

      def progress
        return unless evaluation

        evaluation.progress.merge(remaining: evaluation.progress[:total] - evaluation.progress[:labeled])
      end

      def ready_to_freeze?
        progress && progress[:remaining].zero? && progress[:skipped].zero?
      end
    end

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless facet_confidence_closeout_evaluation?
      return unless issue

      Result.new(type: FACET_CONFIDENCE_CLOSEOUT_EVALUATION, evaluation: issue.facet_confidence_evaluations.latest_first.first)
    end

    private

    attr_reader :notification, :issue

    def facet_confidence_closeout_evaluation?
      notification.source == FACET_CONFIDENCE_CLOSEOUT_EVALUATION ||
        notification.metadata["action_required_type"] == FACET_CONFIDENCE_CLOSEOUT_EVALUATION
    end
  end
end
