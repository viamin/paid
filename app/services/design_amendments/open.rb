# frozen_string_literal: true

module DesignAmendments
  # Opens a design amendment: a product-level change to an approved design
  # that must route through amended RDR/LID PRs, human approval, and merge
  # before affected work resumes (RDR-067 §Human decision and amendment).
  # The amendment binds to the feature intent's current approved revision and
  # moves the feature to `revising`.
  # @spec INTENT-AMENDMENT-003
  class Open
    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, reason:, drift_evidence: {}, design_pr_url: nil)
      @feature_intent = feature_intent
      @reason = reason
      @drift_evidence = drift_evidence
      @design_pr_url = design_pr_url
    end

    def call
      raise DisabledError, "design amendments are disabled for this project" unless enabled?

      DesignAmendment.transaction(requires_new: true) do
        amendment = DesignAmendment.create!(
          project: feature_intent.project,
          feature_intent: feature_intent,
          reason: reason,
          drift_evidence: normalized_evidence,
          design_pr_url: design_pr_url,
          superseded_revision: feature_intent.approved_design_revision
        )
        feature_intent.revise!
        amendment
      end
    end

    private

    attr_reader :feature_intent, :reason, :drift_evidence, :design_pr_url

    # RDR-067 rollout guard: amendment enforcement is off by default and only
    # enabled per project through the feature flag's named enablement surface.
    def enabled?
      FeatureFlags.enabled?(:approved_intent_amendments, project: feature_intent.project)
    end

    def normalized_evidence
      evidence = drift_evidence.is_a?(Hash) ? drift_evidence.deep_stringify_keys : {}
      return evidence if evidence["changed_claims"].present?

      evidence.merge("changed_claims" => [ reason ].compact)
    end
  end
end
