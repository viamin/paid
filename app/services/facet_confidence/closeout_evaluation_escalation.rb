# frozen_string_literal: true

module FacetConfidence
  # Presentation state for an Action Required notification that explicitly
  # routes a maintainer into the persisted closeout-evaluation workflow. The
  # notification contract is structural: callers select this path with a
  # source or metadata value, never by matching human-authored prose.
  # @spec FACET-CONFIDENCE-022
  class CloseoutEvaluationEscalation
    NOTIFICATION_SOURCE = "facet_confidence.closeout_evaluation"
    WORKFLOW_METADATA_KEY = "workflow"
    WORKFLOW_METADATA_VALUE = "facet_confidence_closeout_evaluation"

    Result = Data.define(:issue, :packet, :evaluation, :progress) do
      def ready? = packet.ready?

      def recorded = progress.fetch(:labeled)
      def remaining = progress.fetch(:total) - recorded

      def action
        return :resolve_prerequisites unless ready?
        return :start unless evaluation
        return :completed if evaluation.frozen?
        return :freeze if remaining.zero? && progress.fetch(:skipped).zero?

        :continue
      end
    end

    def self.for(notification)
      return unless typed_notification?(notification)

      new(notification).call
    end

    def self.typed_notification?(notification)
      notification.subject.is_a?(Issue) && (
        notification.source == NOTIFICATION_SOURCE ||
        notification.metadata[WORKFLOW_METADATA_KEY] == WORKFLOW_METADATA_VALUE
      )
    end

    def initialize(notification)
      @notification = notification
      @issue = notification.subject
    end

    def call
      status = Issues::CloseoutStatus.call(issue)
      packet = CloseoutEvaluationPacket.call(issue:, status:)
      evaluation = issue.facet_confidence_evaluations.where(corpus_digest: packet.corpus_digest).latest_first.first
      Result.new(issue:, packet:, evaluation:, progress: progress_for(evaluation, packet))
    end

    private

    attr_reader :notification, :issue

    def progress_for(evaluation, packet)
      return evaluation.progress if evaluation

      { total: packet.input_revisions.size, labeled: 0, skipped: 0 }
    end
  end
end
