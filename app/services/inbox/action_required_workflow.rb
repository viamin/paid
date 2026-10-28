# frozen_string_literal: true

module Inbox
  # Typed, deterministic presentation for Action Required workflows. Unknown
  # types return nil so the caller retains the generic notification fallback.
  # @spec FACET-CONFIDENCE-022 @spec OPERATOR-INBOX-002L
  class ActionRequiredWorkflow
    FACET_CONFIDENCE_TYPE = "facet_confidence_closeout_evaluation"

    Result = Data.define(:type, :title, :explanation, :action_label, :recorded,
      :remaining, :total, :evaluation, :issue)

    def self.call(...) = new(...).call

    def initialize(notification:)
      @notification = notification
    end

    def call
      return unless facet_confidence_workflow?

      progress = evaluation&.progress || empty_progress
      Result.new(type: FACET_CONFIDENCE_TYPE, title: "Human evaluation required",
        explanation: explanation, action_label: action_label(progress),
        recorded: progress[:labeled], remaining: progress[:total] - progress[:labeled],
        total: progress[:total], evaluation:, issue: notification.subject)
    end

    private

    attr_reader :notification

    def facet_confidence_workflow?
      notification.is_a?(Notification) &&
        notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE &&
        notification.subject.is_a?(Issue) &&
        notification.metadata.dig("workflow", "type") == FACET_CONFIDENCE_TYPE
    end

    def evaluation
      @evaluation ||= notification.subject.facet_confidence_evaluations
        .where(corpus_digest: corpus.content_digest).latest_first.first
    end

    def corpus
      @corpus ||= FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
    end

    def empty_progress
      { labeled: 0, total: corpus.case_ids.length }
    end

    def action_label(progress)
      return "Start evaluation" unless evaluation
      return "View evaluation report" if evaluation.frozen?
      return "Freeze judgments" if progress[:labeled] == progress[:total]
      return "Resume evaluation" if progress[:labeled].zero?

      "Continue judging"
    end

    def explanation
      "Work is blocked. An authenticated maintainer must independently review each frozen test case, " \
        "records a judgment from their own reading, and freezes the completed set."
    end
  end
end
