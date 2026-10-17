# frozen_string_literal: true

module FeatureIntents
  # The one deterministic admission gate for implementation work linked to an
  # feature. It intentionally reads the current feature state
  # every time: a run can be queued before a design becomes held again.
  # @spec FEATURE-APPROVAL-023 @spec FEATURE-APPROVAL-024 @spec CONFIDENCE-DELIVERY-005
  class RunAdmission
    Result = Data.define(:allowed, :revision, :reason, :snapshot) do
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
      return confidence_delivery_admission if feature_intent.confidence_driven?
      return denied("Feature intent is not released.") unless feature_intent.released?
      return denied("Feature intent has no approved repository revision.") if feature_intent.approved_design_revision.blank?

      allowed(feature_intent.approved_design_revision)
    end

    private

    attr_reader :issue

    def feature_intent
      @feature_intent ||= FeatureIntent.joins(:feature_intent_issues).find_by(feature_intent_issues: { issue_id: issue.id })
    end

    def allowed(revision = nil, snapshot: {}) = Result.new(allowed: true, revision: revision, reason: nil, snapshot: snapshot)

    def denied(reason) = Result.new(allowed: false, revision: nil, reason: reason, snapshot: {})

    def confidence_delivery_admission
      return denied("Confidence-driven issue has not reconciled its workflow-owned planning hold.") unless link.release_state == "released"

      readiness = ScopedReadiness.call(project: issue.project, mapping: link.readiness_mapping)
      return denied(readiness.blockers.map(&:message).join(" ")) unless readiness.ready?
      return denied("Confidence-driven issue scope changed after release and needs reconciliation.") unless link.release_snapshot["scope_revision"] == readiness.snapshot["scope_revision"]

      allowed(
        link.release_snapshot["merged_baseline"] || readiness.snapshot.dig("design_artifacts", 0, "revision"),
        snapshot: link.release_snapshot
      )
    end

    def link
      @link ||= issue.feature_intent_issue
    end
  end
end
