# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-023
RSpec.describe FeatureIntents::IssueHold do
  it "reports a revising feature distinctly" do
    issue = create(:issue)
    feature = create(:feature_intent, project: issue.project, status: "revising")
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("feature_revising")
    expect(hold.message).to eq("Held: feature revising")
  end

  it "reports an unreleased feature as awaiting release" do
    issue = create(:issue)
    feature = create(:feature_intent, project: issue.project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue).message).to eq("Held: feature awaiting release")
  end

  it "reports a released feature missing its approved revision" do
    issue = create(:issue)
    feature = create(:feature_intent, project: issue.project, approved_design_revision: nil)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue).message).to eq("Held: feature missing approved revision")
  end
end
