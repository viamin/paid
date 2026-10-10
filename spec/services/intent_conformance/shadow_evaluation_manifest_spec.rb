# frozen_string_literal: true

require "rails_helper"

require "time"

module IntentConformance
  module ShadowEvaluationManifest
  end
end

# @spec INTENT-CONFORMANCE-ROLLOUT-002
# @spec INTENT-CONFORMANCE-ROLLOUT-003
RSpec.describe IntentConformance::ShadowEvaluationManifest, :no_db do
  subject(:invalidated_manifest) do
    YAML.safe_load_file(
      Rails.root.join("docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-09.yml")
    )
  end

  describe "the invalidated shadow evaluation manifest" do
    it "cannot be used as rollout measurement evidence" do
      expect(invalidated_manifest).to include(
        "evaluation_status" => "invalidated",
        "invalidation_reason" => a_string_including("not independently content-adjudicated")
      )
    end
  end

  describe "the completed shadow evaluation manifest" do
    subject(:manifest) do
      YAML.safe_load_file(
        Rails.root.join("docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-10.yml")
      )
    end

    it "uses the shadow-only rollout boundary" do
      expect(manifest).to include(
        "evaluation_status" => "completed",
        "repository" => "viamin/paid",
        "enabled_flags" => [ "intent_conformance_shadow_review" ]
      )
      expect(manifest.fetch("disabled_capabilities")).to include(
        "intent_conformance_enforcement",
        "scanner_blocker",
        "inbox_escalation",
        "design_amendments",
        "verify_at_merge"
      )
    end

    it "contains at least ten cases in every adjudicated stratum" do
      cases = manifest.fetch("cases")
      expect(cases.size).to be >= 30
      expect(cases.group_by { |evaluation_case| evaluation_case.fetch("stratum") }.transform_values(&:size)).to include(
        "accepted" => be >= 10,
        "intentionally_drifted" => be >= 10,
        "uncertain" => be >= 10
      )
    end

    it "records blinded independent adjudications after the design revision" do
      cases = manifest.fetch("cases")
      cases.each do |evaluation_case|
        expect(evaluation_case).to include(
          "repository" => "viamin/paid",
          "base_sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "head_sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "approved_design_revision" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "model" => a_string_matching(/\A.+\z/),
          "prompt_version" => a_string_matching(/\A.+\z/),
          "reviewer_outcome" => a_string_matching(/\A.+\z/)
        )
        expect(evaluation_case.fetch("operator_adjudications").size).to eq(2)
        expect(evaluation_case.fetch("operator_adjudications").map { |adjudication| adjudication.fetch("operator") }.uniq.size).to eq(2)
        expect(evaluation_case.fetch("operator_adjudications")).to all(include("outcome", "cited_design_claim", "reason", "adjudicated_at"))
        expect(Time.iso8601(evaluation_case.fetch("adjudicated_at_after_design_revision"))).to be > Time.iso8601(manifest.fetch("approved_design_revision_recorded_at"))
      end

      expect(cases.select { |evaluation_case| evaluation_case["operator_resolution"] }).not_to be_empty
    end
  end
end
