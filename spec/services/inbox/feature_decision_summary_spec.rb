# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-008
RSpec.describe Inbox::FeatureDecisionSummary do
  it "explains readiness when there are no blockers" do
    feature_intent = create(:feature_intent, :ready_for_approval)

    expect(described_class.call(feature_intent: feature_intent)).to eq("Ready for approval.")
  end

  it "explains what holds the feature when it is not ready" do
    feature_intent = create(:feature_intent, :ready_for_approval)
    create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")

    summary = described_class.call(feature_intent: feature_intent)

    expect(summary).to start_with("Held:")
    expect(summary).to include("clarifying question")
  end

  it "explains an approved feature is waiting for its design PRs to merge" do
    approver = create(:user, email: "reviewer@example.com")
    feature_intent = create(:feature_intent, :approved_waiting_for_merge, approved_by: approver)

    summary = described_class.call(feature_intent: feature_intent)

    expect(summary).to eq("Approved by reviewer@example.com. Waiting for the design pull request(s) to merge.")
  end

  it "explains a stale head reopens a hold even after approval" do
    feature_intent = create(:feature_intent, :approved_waiting_for_merge)
    create(:feature_intent_design_pr, :stale, feature_intent: feature_intent, required: true)

    summary = described_class.call(feature_intent: feature_intent)

    expect(summary).to start_with("Held:")
    expect(summary).to include("New commits landed")
  end
end
