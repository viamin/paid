# frozen_string_literal: true

module FeatureIntents
  # The one deterministic admission gate for implementation work linked to an
  # feature. It intentionally reads the current feature state
  # every time: a run can be queued before a design becomes held again.
  # @spec FEATURE-APPROVAL-023 @spec FEATURE-APPROVAL-024
  class RunAdmission
    Result = Data.define(:allowed, :revision, :reason) do
      def allowed? = allowed
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      return allowed unless feature_intent
      return confidence_delivery_unavailable if feature_intent.confidence_driven?
      return denied("Feature intent is not released.") unless feature_intent.released?
      return denied("Feature intent has no approved repository revision.") if feature_intent.approved_design_revision.blank?

      allowed(feature_intent.approved_design_revision)
    end

    private

    attr_reader :issue

    def feature_intent
      @feature_intent ||= FeatureIntent.joins(:feature_intent_issues).find_by(feature_intent_issues: { issue_id: issue.id })
    end

    def allowed(revision = nil) = Result.new(allowed: true, revision: revision, reason: nil)

    def denied(reason) = Result.new(allowed: false, revision: nil, reason: reason)

    # @spec CONFIDENCE-DELIVERY-014
    # P10-P12 will replace this with the unified confidence readiness,
    # policy-specific review, and completion contract. Never fall through to
    # approval-gated admission merely because that older policy is available.
    def confidence_delivery_unavailable
      denied("Confidence-driven delivery is not available until admission, review, and completion integrations are installed.")
    end
  end
end
