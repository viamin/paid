# frozen_string_literal: true

module Inbox
  # Explains what keeps a feature intent held in the Inbox and what would
  # clear it (RDR-066: "The Inbox explains what keeps a feature held and
  # what clears it."). Reads only cached/deterministic state — no live LLM
  # call — so it is safe to call once per Inbox entry per render.
  # @spec FEATURE-APPROVAL-013 CONFIDENCE-DELIVERY-016 OPERATOR-INBOX-019
  class FeatureDecisionSummary
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      return confidence_summary if feature_intent.confidence_driven?

      return approved_waiting_summary if feature_intent.approved_waiting_for_merge? && readiness.ready?
      return "Ready for approval." if readiness.ready?

      "Held: #{readiness.blockers.map(&:message).join(" ")}"
    end

    private

    attr_reader :feature_intent

    def readiness
      @readiness ||= Inbox::FeatureDecisionReadiness.call(feature_intent: feature_intent)
    end

    def approved_waiting_summary
      approver = feature_intent.approved_by&.email || "a project member"
      "Approved by #{approver}. Waiting for the design pull request(s) to merge."
    end

    def confidence_summary
      action = readiness.human_actions.first
      return "Action required: #{action.message}" if action
      return "Scoped readiness is complete; issue release follows normal admission." if readiness.ready?

      "Scoped readiness is being assessed: #{readiness.blockers.map(&:message).join(" ")}"
    end
  end
end
