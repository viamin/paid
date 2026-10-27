# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Recognizes a partial-closeout human-prerequisite Notification that is
    # asking the maintainer to do the shipped facet-confidence reference-
    # judgment evaluation (#4596, closeout #4323/#4662), and reports that
    # evaluation's own state so the generic Action Required Inbox path can
    # route to it directly instead of exposing the raw AI-authored
    # prerequisite text (#4678).
    #
    # Detection is structural, never a text match on the AI-authored
    # prerequisite prose: either the prerequisite explicitly cites the frozen
    # corpus's stable version key — the contract every human gap citing
    # policy/evidence already follows (Llm::AnalyzePartialCloseout) — or the
    # maintainer has already started an evaluation for this issue's current
    # evidence generation.
    # @spec FACET-CONFIDENCE-022
    class InboxEscalation
      Result = Data.define(:corpus_version, :rubric_version, :model_version, :evaluation) do
        PRIMARY_ACTION_LABELS = {
          start: "Start evaluation",
          resume: "Resume evaluation",
          continue: "Continue judging",
          freeze: "Freeze judgments",
          open_report: "Open evaluation and report"
        }.freeze

        def started? = evaluation.present?
        def frozen? = evaluation&.frozen? || false
        def progress = evaluation&.progress

        def primary_action
          return :start unless started?
          return :open_report if frozen?
          return :freeze if fully_labeled?
          return :resume if untouched?

          :continue
        end

        def primary_action_label
          PRIMARY_ACTION_LABELS.fetch(primary_action)
        end

        def title
          {
            start: "Evaluation needs to start",
            resume: "Evaluation is ready to resume",
            continue: "More evaluation judgments are needed",
            freeze: "Evaluation judgments are ready to freeze",
            open_report: "Evaluation report is ready"
          }.fetch(primary_action)
        end

        private

        def fully_labeled?
          progress[:total].positive? && progress[:labeled] == progress[:total]
        end

        def untouched?
          progress[:labeled].zero? && progress[:skipped].zero?
        end
      end

      def self.applicable?(notification:, issue:)
        return false unless issue && notification.partial_closeout_prerequisite?

        cites_corpus?(notification) || issue.facet_confidence_evaluations.exists?
      end

      def self.cites_corpus?(notification)
        corpus_version = corpus.identity.fetch("corpus_version")
        Array(notification.metadata["prerequisites"]).any? do |prerequisite|
          Array(prerequisite["references"]).any? { |reference| reference["key"] == corpus_version }
        end
      end

      def self.corpus
        FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
      end

      def self.call(...) = new(...).call

      def initialize(issue:)
        @issue = issue
      end

      def call
        identity = self.class.corpus.identity
        Result.new(
          corpus_version: identity.fetch("corpus_version"),
          rubric_version: identity.fetch("rubric_version"),
          model_version: identity.fetch("model_version"),
          evaluation: existing_evaluation
        )
      end

      private

      attr_reader :issue

      def existing_evaluation
        issue.facet_confidence_evaluations.where(corpus_digest: self.class.corpus.content_digest).latest_first.first
      end
    end
  end
end
