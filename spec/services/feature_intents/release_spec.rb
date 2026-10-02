# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-016
RSpec.describe FeatureIntents::Release do
  let(:feature) { create(:feature_intent, :approved_waiting_for_merge) }
  let(:revision) { "c" * 40 }

  it "releases only after every required design PR merged at the approved head" do
    design_pr = create(:feature_intent_design_pr, :merged, feature_intent: feature, head_sha: "a" * 40)
    feature.update!(approved_pr_heads: { design_pr.pull_request_number.to_s => design_pr.head_sha })

    result = described_class.call(feature_intent: feature, revision: revision)

    expect(result).to be_released
    expect(feature.reload).to be_released
    expect(feature.approved_design_revision).to eq(revision)
  end

  it "does not release for an incomplete or stale approval" do
    design_pr = create(:feature_intent_design_pr, feature_intent: feature, head_sha: "a" * 40)
    feature.update!(approved_pr_heads: { design_pr.pull_request_number.to_s => "b" * 40 })

    result = described_class.call(feature_intent: feature, revision: revision)

    expect(result).not_to be_released
    expect(feature.reload).to be_approved_waiting_for_merge
  end
end
