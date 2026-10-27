# frozen_string_literal: true

module Inbox
  # Translates Action Required notifications when their source names a
  # first-class in-product workflow. Notifications without a typed workflow
  # intentionally return nil so the Inbox retains its safe generic fallback.
  # @spec FACET-CONFIDENCE-022
  class ActionRequiredPresentation
    Result = Data.define(:title, :summary, :explanation, :action_label, :evaluation,
      :judgments_recorded, :judgments_remaining, :judgments_total)

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless closeout_evaluation?

      result_for(evaluation)
    end

    private

    attr_reader :notification, :issue

    def closeout_evaluation?
      notification.source == PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE && issue.present?
    end

    def evaluation
      evaluations = issue.facet_confidence_evaluations
      return evaluations.target.max_by(&:created_at) if evaluations.loaded?

      evaluations.latest_first.first
    end

    def result_for(existing_evaluation)
      progress = progress_for(existing_evaluation)
      Result.new(
        title: title_for(existing_evaluation, progress),
        summary: "An operator must independently review each frozen test case before this closeout can continue.",
        explanation: "Record a judgment for every test case, then freeze the completed set so the closeout can use the result.",
        action_label: action_label_for(existing_evaluation, progress),
        evaluation: existing_evaluation,
        judgments_recorded: progress[:labeled],
        judgments_remaining: progress[:remaining],
        judgments_total: progress[:total]
      )
    end

    def progress_for(existing_evaluation)
      return { labeled: 0, remaining: 0, total: 0 } unless existing_evaluation

      labels = existing_evaluation.labels.loaded? ? existing_evaluation.labels.target : existing_evaluation.labels.to_a
      labeled = labels.count { |label| label.state == "labeled" }
      total = existing_evaluation.corpus_case_ids.length
      { labeled:, remaining: total - labeled, total: }
    end

    def title_for(existing_evaluation, progress)
      return "Complete the closeout evaluation" unless existing_evaluation&.frozen?
      return "Freeze the closeout judgments" if progress[:remaining].zero?

      "Complete the closeout evaluation"
    end

    def action_label_for(existing_evaluation, progress)
      return "Start evaluation" unless existing_evaluation
      return "View completed evaluation" if existing_evaluation.frozen?
      return "Freeze judgments" if progress[:remaining].zero?

      "Continue judging"
    end
  end
end
