# frozen_string_literal: true

module Inbox
  module ActionRequired
    # A typed Action Required presentation for the human closeout-evaluation
    # step. Selection is structural (the workflow marker/source), never based
    # on notification prose, which is untrusted presentation data.
    # @spec FACET-CONFIDENCE-022 @spec OPERATOR-INBOX-002M
    class FacetConfidenceEvaluation
      WORKFLOW = "facet_confidence_closeout_evaluation"
      SOURCES = [ "facet_confidence.closeout_evaluation", WORKFLOW ].freeze

      Result = Data.define(:title, :description, :action, :action_label, :evaluation,
        :labeled, :skipped, :remaining, :total)

      def self.for(...) = new(...).call

      def initialize(notification:, issue:)
        @notification = notification
        @issue = issue
      end

      def call
        return unless applicable?

        Result.new(**content)
      rescue FacetConfidence::Corpus::MissingManifest,
             FacetConfidence::AssessmentCorpusLedger::InvalidLedger
        nil
      end

      private

      attr_reader :notification, :issue

      def applicable?
        issue.is_a?(Issue) && (workflow_marked? || SOURCES.include?(notification.source))
      end

      def workflow_marked?
        notification.metadata["workflow"] == WORKFLOW
      end

      def content
        return completed_content if evaluation&.frozen?
        return freeze_content if evaluation && remaining.zero? && skipped.zero?
        return continue_content if evaluation

        start_content
      end

      def start_content
        base_content(title: "Complete the closeout evaluation", action: :start, action_label: "Start evaluation")
      end

      def continue_content
        base_content(title: "Continue the closeout evaluation", action: :continue, action_label: "Continue judging")
      end

      def freeze_content
        base_content(title: "Freeze the completed judgments", action: :freeze, action_label: "Freeze judgments")
      end

      def completed_content
        base_content(title: "Closeout evaluation complete", action: :report, action_label: "View evaluation report")
      end

      def base_content(title:, action:, action_label:)
        {
          title: title,
          description: "To finish this closeout, independently review each frozen test case, record your judgment, then freeze the completed set. Paid is waiting for this human review before it can use the result as closeout evidence.",
          action: action,
          action_label: action_label,
          evaluation: evaluation,
          labeled: progress[:labeled],
          skipped: progress[:skipped],
          remaining: remaining,
          total: progress[:total]
        }
      end

      def evaluation
        @evaluation ||= issue.facet_confidence_evaluations.find_by(corpus_digest: corpus_digest)
      end

      def corpus_digest
        @corpus_digest ||= FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).content_digest
      end

      def progress
        @progress ||= evaluation ? evaluation.progress : { total: corpus.case_ids.length, labeled: 0, skipped: 0 }
      end

      def corpus
        @corpus ||= FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
      end

      def remaining = progress[:total] - progress[:labeled]
      def skipped = progress[:skipped]
    end
  end
end
