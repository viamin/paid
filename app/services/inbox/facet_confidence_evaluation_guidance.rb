# frozen_string_literal: true

module Inbox
  # Presentation state for the explicitly typed facet-confidence closeout
  # prerequisite. The workflow marker comes from the structured closeout
  # assessment; notification prose is never classified at render time.
  # @spec OPERATOR-INBOX-002L @spec FACET-CONFIDENCE-022
  class FacetConfidenceEvaluationGuidance
    WORKFLOW = PartialCloseouts::FACET_CONFIDENCE_EVALUATION_WORKFLOW
    Guidance = Data.define(:evaluation, :title, :summary, :action_label, :remaining)

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless issue && workflow_requested?

      evaluation = issue.facet_confidence_evaluations.latest_first.first
      Guidance.new(**state_for(evaluation), evaluation:)
    end

    private

    attr_reader :notification, :issue

    def workflow_requested?
      Array(notification.metadata["prerequisites"]).any? { |prerequisite| prerequisite.is_a?(Hash) && prerequisite["workflow"] == WORKFLOW }
    end

    def state_for(evaluation)
      return start_state unless evaluation
      return complete_state if evaluation.frozen?

      labeling_state(evaluation.progress)
    end

    def start_state
      {
        title: "Evaluation needed for issue ##{issue.github_number}",
        summary: "Review each frozen test case independently before this closeout can be verified.",
        action_label: "Start evaluation",
        remaining: "Start the evaluation, record a judgment for every test case, then freeze the completed set."
      }
    end

    def labeling_state(progress)
      remaining = progress[:total] - progress[:labeled]
      {
        title: "Evaluation in progress for issue ##{issue.github_number}",
        summary: "#{progress[:labeled]} of #{progress[:total]} judgments recorded; #{remaining} remaining.",
        action_label: remaining.zero? ? "Freeze judgments" : progress[:labeled].zero? ? "Resume evaluation" : "Continue judging",
        remaining: remaining.zero? ? "Review the completed judgments and freeze the set." : "Record #{remaining} remaining #{'judgment'.pluralize(remaining)} before freezing the set."
      }
    end

    def complete_state
      {
        title: "Evaluation complete for issue ##{issue.github_number}",
        summary: "All judgments are frozen and the evaluation report is ready to review.",
        action_label: "Open evaluation report",
        remaining: "Review the completed report before deciding the closeout's next step."
      }
    end
  end
end
