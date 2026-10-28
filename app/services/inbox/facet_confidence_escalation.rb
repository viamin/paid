# frozen_string_literal: true

module Inbox
  # Projects only explicitly typed closeout-evaluation escalations into the
  # facet-confidence workflow. Other Action Required notifications retain the
  # generic, metadata-driven fallback.
  # @spec FACET-CONFIDENCE-022
  class FacetConfidenceEscalation
    WORKFLOW_TYPE = "facet_confidence_closeout_evaluation"
    SOURCE = "closeout_evaluation_required"

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless applicable?

      evaluation = current_evaluation
      progress = evaluation&.progress
      {
        type: WORKFLOW_TYPE,
        title: "Evaluation needed before this closeout can move forward",
        explanation: "A human needs to independently review each frozen test case, record a judgment for every case, and freeze the completed set.",
        evaluation_id: evaluation&.id,
        recorded: progress&.fetch(:labeled, 0) || 0,
        total: progress&.fetch(:total, 0) || FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.length,
        skipped: progress&.fetch(:skipped, 0) || 0,
        action_label: action_label(evaluation, progress)
      }
    end

    private

    attr_reader :notification, :issue

    def applicable?
      issue.is_a?(Issue) && (notification.source == SOURCE || notification.metadata["action_workflow"] == WORKFLOW_TYPE)
    end

    def current_evaluation
      issue.facet_confidence_evaluations.latest_first.first
    end

    def action_label(evaluation, progress)
      return "Start evaluation" unless evaluation
      return "View completed evaluation" if evaluation.frozen?
      return "Resume evaluation" if progress.fetch(:labeled).zero? && progress.fetch(:skipped).zero?
      return "Freeze judgments" if progress.fetch(:labeled) == progress.fetch(:total) && progress.fetch(:skipped).zero?

      "Continue judging"
    end
  end
end
