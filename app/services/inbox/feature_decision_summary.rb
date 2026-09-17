# frozen_string_literal: true

module Inbox
  # Explains what keeps a feature intent held in the Inbox and what would
  # clear it (RDR-066: "The Inbox explains what keeps a feature held and
  # what clears it."). Reads only cached/deterministic state — no live LLM
  # call — so it is safe to call once per Inbox entry per render.
  # @spec FEATURE-APPROVAL-013
  class FeatureDecisionSummary
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      return approved_waiting_summary if feature_intent.approved_waiting_for_merge? && readiness.ready?
      return "Ready for approval." if readiness.ready?

      "Held: #{readiness.blockers.map(&:message).join(" ")}"
    end

    private

    attr_reader :feature_intent

    def readiness
      @readiness ||= FeatureIntents::ApprovalReadiness.call(feature_intent: feature_intent)
    end

    def approved_waiting_summary
      approver = feature_intent.approved_by&.email || "a project member"
      "Approved by #{approver}. Waiting for the design pull request(s) to merge."
    end
  end
end
