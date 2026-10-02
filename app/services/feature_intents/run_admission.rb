# frozen_string_literal: true

module FeatureIntents
  # The one deterministic admission gate for implementation work linked to an
  # approval-gated feature. It intentionally reads the current feature state
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
  end
end
