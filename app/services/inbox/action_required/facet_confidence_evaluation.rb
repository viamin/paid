# frozen_string_literal: true

module Inbox
  module ActionRequired
    # @spec OPERATOR-INBOX-002L FACET-CONFIDENCE-022
    # Translates the explicitly typed closeout-evaluation escalation without
    # inspecting producer prose. A missing or unknown type deliberately falls
    # through to the generic Action Required presentation.
    class FacetConfidenceEvaluation
      REMEDIATION_TYPE = "facet_confidence_closeout_evaluation"

      Result = Data.define(:title, :explanation, :progress, :action_label, :evaluation)

      def self.call(...) = new(...).call

      def initialize(notification:, issue:)
        @notification = notification
        @issue = issue
      end

      def call
        return unless notification.metadata["remediation_type"] == REMEDIATION_TYPE
        return unless issue

        presentation
      end

      private

      attr_reader :notification, :issue

      def presentation
        Result.new(
          title: title,
          explanation: explanation,
          progress: progress,
          action_label: action_label,
          evaluation: evaluation
        )
      end

      def evaluation
        @evaluation ||= issue.facet_confidence_evaluations.latest_first.first
      end

      def progress
        return evaluation.progress if evaluation

        { total: corpus.case_ids.length, labeled: 0, skipped: 0 }
      end

      def corpus
        @corpus ||= FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
      end

      def title
        return "Evaluation needed" unless evaluation
        return "Evaluation complete" if evaluation.frozen?
        return "Ready to freeze judgments" if remaining.zero?

        "Evaluation in progress"
      end

      def explanation
        return "Review each test case independently, record your judgment, then freeze the completed set." unless evaluation
        return "All judgments are recorded and frozen. Review the completed evaluation report." if evaluation.frozen?
        return "Every test case has a recorded judgment. Freeze the completed set to finish the evaluation." if remaining.zero?

        "Review the remaining test cases independently and record a judgment for each one before freezing the set."
      end

      def action_label
        return "Start evaluation" unless evaluation
        return "View evaluation report" if evaluation.frozen?
        return "Freeze judgments" if remaining.zero?
        return "Resume evaluation" if progress[:labeled].zero?

        "Continue judging"
      end

      def remaining = progress[:total] - progress[:labeled]
    end
  end
end
