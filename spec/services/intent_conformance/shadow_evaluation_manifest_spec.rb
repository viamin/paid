# frozen_string_literal: true

require "rails_helper"

module IntentConformance
  module ShadowEvaluationManifest
  end
end

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

  describe "the invalidated October 10 shadow evaluation manifest" do
    subject(:manifest) do
      YAML.safe_load_file(
        Rails.root.join("docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-10.yml")
      )
    end

    it "cannot be used as rollout measurement evidence" do
      expect(manifest).to include(
        "evaluation_status" => "invalidated",
        "invalidation_reason" => a_string_including("committed before its purported adjudications")
      )
      expect(manifest.fetch("frozen_at")).to be_nil
    end

    it "retains the rejected payload only as an audit trail" do
      expect(manifest.fetch("cases")).not_to be_empty
    end
  end
end
