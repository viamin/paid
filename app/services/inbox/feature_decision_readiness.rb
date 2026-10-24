# frozen_string_literal: true

module Inbox
  # Projects each delivery policy's gate into the shared Inbox lane.
  # @spec CONFIDENCE-DELIVERY-016 OPERATOR-INBOX-019
  class FeatureDecisionReadiness
    Result = Data.define(:ready, :blockers, :human_actions) do
      def ready? = ready
      def actionable? = human_actions.any?
    end
    HumanAction = Data.define(:kind, :message)

    def self.call(...) = new(...).call

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      return approval_readiness unless feature_intent.confidence_driven?

      confidence_readiness
    end

    private

    attr_reader :feature_intent

    def approval_readiness
      readiness = FeatureIntents::ApprovalReadiness.call(feature_intent: feature_intent)
      actions = readiness.ready? ? [ HumanAction.new(kind: "approve", message: "Review the design and mark it approved.") ] : open_decision_actions
      Result.new(ready: readiness.ready?, blockers: readiness.blockers, human_actions: actions)
    end

    def confidence_readiness
      blockers = feature_intent.feature_intent_issues.flat_map do |issue_link|
        FeatureIntents::ScopedReadiness.call(project: feature_intent.project, mapping: issue_link.current_readiness_mapping).blockers
      end
      Result.new(ready: blockers.empty?, blockers: blockers, human_actions: open_decision_actions)
    end

    def open_decision_actions
      feature_intent.feature_intent_decisions.select(&:open?).map do |decision|
        kind = decision.question? ? "answer_or_clarify" : "choose_direction"
        HumanAction.new(kind: kind, message: "#{decision.prompt} Affects: #{decision.design_claim}")
      end
    end
  end
end
