# frozen_string_literal: true

module Inbox
  # Typed projections for Action Required notifications. A workflow is chosen
  # only from the producer's stable source and metadata contract; notification
  # prose remains display data and can never select an action.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredGuidance
    FACET_CONFIDENCE_CLOSEOUT_EVALUATION_SOURCE = "facet_confidence.closeout_evaluation"
    FACET_CONFIDENCE_CLOSEOUT_EVALUATION_WORKFLOW = "facet_confidence_closeout_evaluation"

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      facet_confidence_closeout_evaluation if facet_confidence_closeout_evaluation?
    end

    private

    attr_reader :notification, :issue

    def facet_confidence_closeout_evaluation?
      issue.is_a?(Issue) &&
        notification.source == FACET_CONFIDENCE_CLOSEOUT_EVALUATION_SOURCE &&
        notification.metadata["workflow"] == FACET_CONFIDENCE_CLOSEOUT_EVALUATION_WORKFLOW
    end

    def facet_confidence_closeout_evaluation
      evaluation = issue.facet_confidence_evaluations.max_by(&:created_at)
      progress = progress_for(evaluation)
      action = action_for(evaluation, progress)
      {
        workflow: FACET_CONFIDENCE_CLOSEOUT_EVALUATION_WORKFLOW,
        title: title_for(action),
        explanation: explanation_for(action),
        action: action,
        evaluation: evaluation,
        recorded: progress[:recorded],
        remaining: progress[:remaining],
        total: progress[:total]
      }
    end

    def progress_for(evaluation)
      return { recorded: 0, remaining: 0, total: 0 } unless evaluation

      labels = evaluation.labels.to_a
      total = evaluation.corpus_case_ids.length
      recorded = labels.count(&:labeled?)
      { recorded: recorded, remaining: total - recorded, total: total }
    end

    def action_for(evaluation, progress)
      return :start unless evaluation
      return :view_report if evaluation.frozen?
      return :freeze if progress[:remaining].zero?

      :continue_judging
    end

    def title_for(action)
      {
        start: "Start the closeout evaluation",
        continue_judging: "Continue the closeout evaluation",
        freeze: "Freeze completed judgments",
        view_report: "Closeout evaluation complete"
      }.fetch(action)
    end

    def explanation_for(action)
      case action
      when :start
        "This closeout is blocked until a human independently reviews every test case and records a judgment."
      when :continue_judging
        "Independently review each remaining test case and record a judgment before the set can be completed."
      when :freeze
        "Every test case has a recorded judgment. Freeze the completed set to finish the evaluation."
      when :view_report
        "The completed judgment set is available to review with its evaluation report."
      end
    end
  end
end
