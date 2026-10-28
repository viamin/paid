# frozen_string_literal: true

require "digest"

module Inbox
  # Typed, presentational projection for an Action Required notification that
  # is known to be resolved by the facet-confidence evaluation flow. The
  # workflow discriminator is structured notification metadata; this class
  # never guesses from notification prose.
  # @spec FACET-CONFIDENCE-022
  class FacetConfidenceEvaluationEscalation
    WORKFLOW = "facet_confidence_closeout_evaluation"

    Result = Data.define(:title, :summary, :action_label, :evaluation, :progress) do
      def start? = evaluation.nil?
    end

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless typed_workflow?
      return unless issue

      Result.new(
        title: "Independent review of test cases is needed",
        summary: summary,
        action_label: action_label,
        evaluation: evaluation,
        progress: progress
      )
    end

    private

    attr_reader :notification, :issue

    def typed_workflow?
      notification.metadata["action_required_workflow"] == WORKFLOW ||
        notification.source == "facet_confidence.closeout_evaluation"
    end

    def evaluation
      return @evaluation if defined?(@evaluation)

      @evaluation = issue.facet_confidence_evaluations
        .where(corpus_digest: corpus_digest)
        .latest_first
        .first
    end

    def corpus_digest
      @corpus_digest ||= Digest::SHA256.file(Rails.root.join(FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)).hexdigest
    end

    def progress
      @progress ||= evaluation&.progress || { labeled: 0, total: corpus.case_ids.length, skipped: 0 }
    end

    def corpus
      @corpus ||= FacetConfidence::Corpus.new(
        path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
        digest: corpus_digest
      )
    end

    def remaining = progress[:total] - progress[:labeled]

    def summary
      if evaluation&.frozen?
        "The completed judgment set is frozen. You can review the evaluation report."
      else
        "Review each frozen test case yourself, record a judgment for every case, then freeze the completed set."
      end
    end

    def action_label
      return "Start evaluation" unless evaluation
      return "View evaluation" if evaluation.frozen?
      return "Resume evaluation" if progress[:labeled].zero?
      return "Freeze judgments" if remaining.zero?

      "Continue judging"
    end
  end
end
