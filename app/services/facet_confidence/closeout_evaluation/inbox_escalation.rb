# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Typed bridge between a partial-closeout escalation and its human
    # evaluation workflow. The marker is durable notification metadata, not
    # an inference from notification prose, so unrelated prerequisites retain
    # the generic Action Required presentation.
    # @spec FACET-CONFIDENCE-022
    class InboxEscalation
      WORKFLOW = "facet_confidence_closeout_evaluation"

      def self.for(notification)
        new(notification).then { _1 if _1.applicable? }
      end

      def self.active_for?(issue)
        Notification.active.where(
          account: issue.project.account,
          subject: issue,
          source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE
        ).any? { |notification| notification.metadata["workflow"] == WORKFLOW }
      end

      def initialize(notification)
        @notification = notification
      end

      def applicable?
        notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE &&
          notification.subject.is_a?(Issue) && notification.metadata["workflow"] == WORKFLOW
      end

      def evaluation
        @evaluation ||= issue.facet_confidence_evaluations.latest_first.first
      end

      def title = "Independent evaluation needed"

      def explanation
        "This closeout is blocked until a maintainer independently reviews each frozen test case. " \
          "Record a judgment for every case, then freeze the completed set so the closeout has human evidence."
      end

      def action_label
        return "Start evaluation" unless evaluation
        return "View completed evaluation" if evaluation.frozen?
        return "Resume evaluation" if progress.fetch(:labeled).zero? && progress.fetch(:skipped).zero?
        return "Freeze judgments" if remaining.zero? && progress.fetch(:skipped).zero?

        "Continue judging"
      end

      def progress
        @progress ||= evaluation&.progress || {
          total: FacetConfidence::Corpus.new(path: CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.length,
          labeled: 0,
          skipped: 0
        }
      end

      def remaining
        progress.fetch(:total) - progress.fetch(:labeled) - progress.fetch(:skipped)
      end

      def progress_message
        return "The completed set is frozen and its report is available." if evaluation&.frozen?

        message = "#{progress.fetch(:labeled)} of #{progress.fetch(:total)} judgments recorded; #{remaining} remaining."
        if progress.fetch(:skipped).positive?
          message += " #{progress.fetch(:skipped)} skipped case#{'s' unless progress.fetch(:skipped) == 1} must be judged before freezing."
        end
        message
      end

      private

      attr_reader :notification

      def issue = notification.subject
    end
  end
end
