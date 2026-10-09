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

  describe "the invalidated shadow evaluation manifest" do
    it "cannot be used as rollout measurement evidence" do
      expect(manifest).to include(
        "evaluation_status" => "invalidated",
        "invalidation_reason" => a_string_including("not independently content-adjudicated")
      )
    end
  end
end
