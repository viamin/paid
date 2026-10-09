# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-002
# @spec INTENT-CONFORMANCE-ROLLOUT-003
RSpec.describe IntentConformance::ReviewRun do
  subject(:manifest) do
    YAML.safe_load_file(
      Rails.root.join("docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-09.yml")
    )
  end

  describe "the shadow evaluation manifest" do
    it "freezes independently adjudicated representative cases for every required stratum" do
      cases = manifest.fetch("cases")

      expect(cases.size).to be >= 30
      expect(cases.group_by { |evaluation_case| evaluation_case.fetch("stratum") }.transform_values(&:size))
        .to include("accepted" => be >= 10, "intentionally_drifted" => be >= 10, "uncertain" => be >= 10)

      cases.each do |evaluation_case|
        expect(evaluation_case).to include(
          "repository" => "viamin/paid",
          "base_sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "head_sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "approved_design_revision" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "model" => "claude-sonnet-4-6",
          "prompt_version" => "review-run-v1"
        )
        expect(evaluation_case.fetch("operator_adjudications").size).to eq(2)
        expect(evaluation_case.fetch("blindness")).to eq("reviewer_output_withheld_until_both_adjudications_locked")
      end
    end

    it "retains a third-operator resolution for every independent disagreement" do
      manifest.fetch("cases").each do |evaluation_case|
        outcomes = evaluation_case.fetch("operator_adjudications").pluck("outcome").uniq
        resolution = evaluation_case["disagreement_resolution"]

        if outcomes.one?
          expect(resolution).to be_nil
        else
          expect(resolution).to include("operator", "outcome", "cited_design_claim", "reason", "resolved_at")
        end
      end
    end
  end
end
