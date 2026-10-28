# frozen_string_literal: true

module Inbox
  class ActionRequiredWorkflow
    FACET_CONFIDENCE = "facet_confidence_evaluation"

    def self.for(notification)
      return unless notification.metadata["in_product_action"] == FACET_CONFIDENCE
      return unless notification.subject.is_a?(Issue)

      new(notification)
    end

    attr_reader :notification, :issue, :evaluation

    def initialize(notification)
      @notification = notification
      @issue = notification.subject
      @evaluation = issue.facet_confidence_evaluations.latest_first.first
    end

    def progress
      evaluation&.progress || { total: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).case_ids.size,
        labeled: 0, skipped: 0 }
    end

    def remaining = progress[:total] - progress[:labeled]

    def action_label
      return "Start evaluation" unless evaluation
      return "Open evaluation report" if evaluation.frozen?
      return "Freeze judgments" if remaining.zero? && progress[:skipped].zero?

      "Continue judging"
    end

    def action_path(entry)
      context = { inbox_kind: entry.kind, inbox_entry_id: entry.id }
      return Rails.application.routes.url_helpers.new_project_facet_confidence_evaluation_path(issue.project, issue_id: issue.id, **context) unless evaluation

      Rails.application.routes.url_helpers.project_facet_confidence_evaluation_path(issue.project, evaluation, **context)
    end
  end
end
