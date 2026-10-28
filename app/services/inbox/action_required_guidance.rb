# frozen_string_literal: true

module Inbox
  # Projects typed notification workflow metadata into safe, user-facing Inbox
  # guidance. Unknown metadata deliberately returns nil so generic Action
  # Required notifications keep their existing rendering path.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredGuidance
    FACET_CONFIDENCE_EVALUATION = "facet_confidence_evaluation"

    Result = Data.define(:title, :explanation, :action_label, :action_path, :progress, :remaining)

    def self.call(...) = new(...).call

    def initialize(notification:, project:, issue:, inbox_context: {})
      @notification = notification
      @project = project
      @issue = issue
      @inbox_context = inbox_context
    end

    def call
      return unless facet_confidence_evaluation?

      evaluation ? existing_evaluation_guidance : start_evaluation_guidance
    end

    private

    attr_reader :inbox_context, :issue, :notification, :project

    def facet_confidence_evaluation?
      notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE &&
        issue.present? &&
        Array(notification.metadata["prerequisites"]).any? do |prerequisite|
          prerequisite.is_a?(Hash) && prerequisite["workflow"] == FACET_CONFIDENCE_EVALUATION
        end
    end

    def evaluation
      @evaluation ||= issue.facet_confidence_evaluations.latest_first.first
    end

    def start_evaluation_guidance
      Result.new(
        title: "Complete evaluation",
        explanation: "This closeout is waiting for an independent human review. Review each frozen test case independently, record your judgment for every case, then freeze the completed set.",
        action_label: "Start evaluation",
        action_path: Rails.application.routes.url_helpers.new_project_facet_confidence_evaluation_path(project, issue_id: issue.id, **inbox_context),
        progress: "0 judgments recorded",
        remaining: "All test cases remain to be judged."
      )
    end

    def existing_evaluation_guidance
      progress = evaluation.progress
      remaining = progress[:total] - progress[:labeled]
      Result.new(
        title: "Complete evaluation",
        explanation: "This closeout is waiting for an independent human review. Review each frozen test case independently, record your judgment for every case, then freeze the completed set.",
        action_label: action_label(progress, remaining),
        action_path: Rails.application.routes.url_helpers.project_facet_confidence_evaluation_path(project, evaluation, **inbox_context),
        progress: "#{progress[:labeled]} judgments recorded out of #{progress[:total]}",
        remaining: remaining.zero? ? "Every test case is judged; freeze the completed set." : "#{remaining} test #{'case'.pluralize(remaining)} remaining."
      )
    end

    def action_label(progress, remaining)
      return "View completed evaluation" if evaluation.frozen?
      return "Freeze judgments" if remaining.zero? && progress[:skipped].zero?

      "Continue judging"
    end
  end
end
