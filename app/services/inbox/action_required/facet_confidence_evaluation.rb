# frozen_string_literal: true

module Inbox
  module ActionRequired
    # Translates the typed closeout-evaluation escalation into the operator's
    # actual task. The workflow discriminator comes from the semantic closeout
    # assessment; this presenter only reads the persisted type and lifecycle.
    # @spec FACET-CONFIDENCE-022
    class FacetConfidenceEvaluation
      WORKFLOW = "facet_confidence_closeout_evaluation"

      def self.for(notification:, issue:)
        return unless notification.respond_to?(:metadata)
        return unless notification.metadata.to_h["operator_workflow"] == WORKFLOW
        return unless issue

        new(issue).presentation
      end

      def initialize(issue)
        @issue = issue
      end

      def presentation
        evaluation = issue.facet_confidence_evaluations.where(corpus_digest: packet.corpus_digest).latest_first.first
        return start_presentation unless evaluation

        progress = evaluation.progress
        {
          title: title_for(evaluation, progress), explanation: explanation_for(evaluation, progress),
          action_label: action_label_for(evaluation, progress), evaluation: evaluation, progress: progress
        }
      end

      private

      attr_reader :issue

      def packet
        @packet ||= FacetConfidence::CloseoutEvaluationPacket.call(issue: issue, status: Issues::CloseoutStatus.call(issue))
      end

      def start_presentation
        { title: "Independent evaluation needed", explanation: "This closeout is blocked until a maintainer independently reviews every frozen test case, records a judgment for each one, and freezes the completed set.", action_label: "Start evaluation", evaluation: nil, progress: nil }
      end

      def title_for(evaluation, progress)
        return "Evaluation complete" if evaluation.frozen?
        return "Judgments ready to freeze" if progress[:labeled] == progress[:total]

        "Independent evaluation in progress"
      end

      def explanation_for(evaluation, progress)
        return "The completed judgment set is frozen. Open the report to review the recorded evidence." if evaluation.frozen?
        return "Every test case has a recorded judgment. Review the set and freeze it to complete this evaluation." if progress[:labeled] == progress[:total]

        "A maintainer must independently review each frozen test case and record a judgment before the completed set can be frozen."
      end

      def action_label_for(evaluation, progress)
        return "View completed evaluation" if evaluation.frozen?
        return "Freeze judgments" if progress[:labeled] == progress[:total]
        return "Continue judging" if progress[:labeled].positive?

        "Resume evaluation"
      end
    end
  end
end
