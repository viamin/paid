# frozen_string_literal: true

module Inbox
  # Typed, deterministic presentation for a blocking notification that routes
  # an operator into the existing facet-confidence closeout evaluation. The
  # producer declares the workflow in metadata; this never guesses intent from
  # notification prose.
  # @spec OPERATOR-INBOX-002B @spec FACET-CONFIDENCE-022
  class ActionRequiredWorkflow
    FACET_CONFIDENCE_CLOSEOUT_EVALUATION = "facet_confidence_closeout_evaluation"

    Presentation = Data.define(:title, :explanation, :action_label, :evaluation, :progress, :remaining_action)

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless notification.metadata["action_workflow"] == FACET_CONFIDENCE_CLOSEOUT_EVALUATION
      return unless issue

      evaluation = issue.facet_confidence_evaluations.latest_first.first
      Presentation.new(
        title: "Human evaluation needed",
        explanation: "This work is blocked until a maintainer independently reviews each test case, records a judgment, and freezes the completed set.",
        action_label: action_label(evaluation),
        evaluation: evaluation,
        progress: progress(evaluation),
        remaining_action: remaining_action(evaluation)
      )
    end

    private

    attr_reader :notification, :issue

    def action_label(evaluation)
      return "Start evaluation" unless evaluation
      return "View completed evaluation" if evaluation.frozen?
      return "Freeze judgments" if progress(evaluation)[:remaining].zero?

      "Continue judging"
    end

    def progress(evaluation)
      return { labeled: 0, total: nil, remaining: nil } unless evaluation

      counts = evaluation.progress
      counts.merge(remaining: counts[:total] - counts[:labeled] - counts[:skipped])
    end

    def remaining_action(evaluation)
      return "Start the evaluation to review every test case." unless evaluation
      return "The completed set is frozen." if evaluation.frozen?
      return "All judgments are recorded. Freeze the completed set." if progress(evaluation)[:remaining].zero?

      "Record the remaining judgments, then freeze the completed set."
    end
  end
end
