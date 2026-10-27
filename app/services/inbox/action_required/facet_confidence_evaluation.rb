# frozen_string_literal: true

module Inbox
  module ActionRequired
    # Presentation state for the explicit facet-confidence closeout action.
    # The action is selected from publisher-owned metadata, never from the
    # notification's human-readable text.
    # @spec OPERATOR-INBOX-002L
    # @spec FACET-CONFIDENCE-022
    class FacetConfidenceEvaluation
      TYPE = "facet_confidence_closeout_evaluation"

      Result = Data.define(:issue, :evaluation, :progress, :judge) do
        def started? = evaluation.present?
        def complete? = evaluation&.frozen?
        def ready_to_freeze? = judge && evaluation&.labeling? && progress[:remaining].zero?
        def remaining? = judge && started? && !complete? && !ready_to_freeze?
      end

      def self.for(notification, user:)
        return unless notification.metadata["inbox_action"] == TYPE
        return unless notification.subject.is_a?(Issue)

        new(notification.subject, user).result
      end

      def initialize(issue, user)
        @issue = issue
        @user = user
      end

      def result
        Result.new(issue:, evaluation:, progress:, judge: evaluation&.created_by_id == user.id)
      end

      private

      attr_reader :issue, :user

      def evaluation
        @evaluation ||= issue.facet_confidence_evaluations.latest_first.first
      end

      def progress
        return empty_progress unless evaluation

        current = evaluation.progress
        current.merge(recorded: current[:labeled], remaining: current[:total] - current[:labeled])
      end

      def empty_progress
        total = FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.length
        { recorded: 0, total:, remaining: total }
      end
    end
  end
end
