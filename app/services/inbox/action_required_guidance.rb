# frozen_string_literal: true

module Inbox
  # Typed presentations for blocking notifications.  The notification remains
  # the source of truth; a typed marker lets the Inbox offer a real workflow
  # without trying to infer meaning from agent-authored prose.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredGuidance
    FACET_CONFIDENCE_CLOSEOUT_EVALUATION = "facet_confidence_closeout_evaluation"

    Result = Data.define(:title, :explanation, :action_label, :evaluation, :progress) do
      def remaining = progress[:total] - progress[:labeled]
    end

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless workflow == FACET_CONFIDENCE_CLOSEOUT_EVALUATION
      return unless issue

      evaluation = issue.facet_confidence_evaluations.latest_first.first
      Result.new(
        title: "Human evaluation needed",
        explanation: explanation_for(evaluation),
        action_label: action_label_for(evaluation),
        evaluation: evaluation,
        progress: evaluation&.progress || { total: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.length, labeled: 0, skipped: 0 }
      )
    end

    private

    attr_reader :notification, :issue

    def workflow = notification.metadata["workflow"]

    def explanation_for(evaluation)
      return "This closeout is blocked until a person independently reviews every frozen test case, records a judgment for each one, and freezes the completed set." unless evaluation

      progress = evaluation.progress
      return "All #{progress[:total]} judgments are recorded. Freeze the completed set to finish this evaluation." if progress[:labeled] == progress[:total]

      "This closeout is blocked until a person independently reviews every frozen test case and records a judgment. #{progress[:labeled]} of #{progress[:total]} judgments are recorded; #{progress[:total] - progress[:labeled]} remain."
    end

    def action_label_for(evaluation)
      return "Start evaluation" unless evaluation
      return "Freeze judgments" if evaluation.progress[:labeled] == evaluation.progress[:total]

      "Continue judging"
    end
  end
end
