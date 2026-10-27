# frozen_string_literal: true

module Inbox
  # Presents a declared closeout-evaluation workflow without interpreting the
  # notification's prose. The publisher supplies the workflow type; this
  # adapter only reads persisted evaluation state to choose a safe next action.
  # @spec FACET-CONFIDENCE-022 OPERATOR-INBOX-002L
  class FacetConfidenceEvaluationAction
    WORKFLOW = "facet_confidence_evaluation"
    Result = Data.define(:evaluation, :action, :recorded, :remaining, :total) do
      def title = "Complete closeout evaluation"

      def summary = "Independently review each frozen test case and record the remaining judgments."

      def frozen? = action == :open
    end

    def self.call(...) = new(...).call

    def initialize(notification:, issue:)
      @notification = notification
      @issue = issue
    end

    def call
      return unless notification.metadata["workflow"] == WORKFLOW
      return unless issue

      evaluation = issue.facet_confidence_evaluations.latest_first.first
      return Result.new(evaluation: nil, action: :start, recorded: 0, remaining: nil, total: nil) unless evaluation

      progress = evaluation.progress
      recorded = progress.fetch(:labeled)
      total = progress.fetch(:total)
      Result.new(evaluation:, action: action_for(evaluation, recorded, total), recorded:, remaining: total - recorded, total:)
    end

    private

    attr_reader :notification, :issue

    def action_for(evaluation, recorded, total)
      return :open if evaluation.frozen?
      return :freeze if recorded == total

      :continue
    end
  end
end
