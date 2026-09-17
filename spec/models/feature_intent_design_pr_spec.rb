# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-003
RSpec.describe FeatureIntentDesignPr do
  it "is stale when the head moved past the last reviewed head" do
    design_pr = build(:feature_intent_design_pr, :stale)

    expect(design_pr).to be_stale
  end

  it "is not stale when the head matches the last reviewed head" do
    design_pr = build(:feature_intent_design_pr, head_sha: "a" * 40, reviewed_head_sha: "a" * 40)

    expect(design_pr).not_to be_stale
  end

  it "is not stale when it has never been reviewed" do
    design_pr = build(:feature_intent_design_pr, head_sha: "a" * 40, reviewed_head_sha: nil)

    expect(design_pr).not_to be_stale
  end

  it "is unique per feature intent and PR number" do
    feature_intent = create(:feature_intent)
    create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 5)

    duplicate = build(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 5)

    expect(duplicate).not_to be_valid
  end

  it "builds a GitHub PR URL from the project and PR number" do
    project = create(:project, owner: "viamin", repo: "paid")
    feature_intent = create(:feature_intent, project: project)
    design_pr = create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 42)

    expect(design_pr.github_url).to eq("https://github.com/viamin/paid/pull/42")
  end
end
