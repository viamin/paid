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

  it "does not project an implementation approval hold onto a planning task" do # @spec CONFIDENCE-DELIVERY-017
    issue = create(:issue)
    feature = create(:feature_intent, project: issue.project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      readiness_mapping: { "planning_hold" => { "owner" => "paid", "task_kind" => "planning", "operator_override" => false } })

    expect(described_class.call(issue: issue)).to be_nil
  end

  it "reports a released feature missing its approved revision" do
    issue = create(:issue)
    feature = create(:feature_intent, project: issue.project, approved_design_revision: nil)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue).message).to eq("Held: feature missing approved revision")
  end

  it "reports a held confidence-driven link using its recorded release_error" do
    issue = create(:issue)
    feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "held",
      release_error: "Material prerequisite coverage has not been confirmed.")

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("confidence_release_held")
    expect(hold.message).to include("confidence link holds")
    expect(hold.message).to include("coverage has not been confirmed")
  end

  it "falls back to a stable message when a held confidence link has no release_error" do
    issue = create(:issue)
    feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "held", release_error: nil)

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("confidence_release_held")
    expect(hold.message).to include("planning-hold reconciliation pending")
  end

  it "reports a pending confidence-driven link distinctly" do
    issue = create(:issue)
    feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue, release_state: "pending")

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("confidence_release_pending")
    expect(hold.message).to eq("Held: confidence link pending planning-hold reconciliation")
  end

  it "reports a reconciliation-failed confidence-driven link with the recorded error" do
    issue = create(:issue)
    feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "reconciliation_failed",
      release_error: "Planning-hold reconciliation failed: upstream returned 502")

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("confidence_release_reconciliation_failed")
    expect(hold.message).to include("reconciliation failed")
    expect(hold.message).to include("502")
  end

  it "does not project a hold for an already-released confidence-driven link" do
    issue = create(:issue)
    feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "released",
      released_at: Time.current,
      release_snapshot: { "scope_revision" => "scope-v1" })

    expect(described_class.call(issue: issue)).to be_nil
  end

  it "scopes the hold to the requested feature when one is supplied" do
    issue = create(:issue)
    held_feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: held_feature, issue: issue,
      release_state: "held",
      release_error: "Material prerequisite coverage has not been confirmed.")
    released_feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: released_feature, issue: issue,
      release_state: "released",
      released_at: Time.current,
      release_snapshot: { "scope_revision" => "scope-v1" })

    expect(described_class.call(issue: issue, feature: released_feature)).to be_nil

    scoped_hold = described_class.call(issue: issue, feature: held_feature)
    expect(scoped_hold.code).to eq("confidence_release_held")
  end

  it "prefers an approval-gated hold over a confidence-driven hold when both apply" do
    issue = create(:issue)
    approval_feature = create(:feature_intent, project: issue.project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: approval_feature, issue: issue)
    confidence_feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: confidence_feature, issue: issue,
      release_state: "held", release_error: "Material prerequisite coverage has not been confirmed.")

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("feature_not_released")
  end

  it "prefers an approval-gated hold regardless of link creation order" do
    issue = create(:issue)
    confidence_feature = create(:feature_intent, :confidence_driven, project: issue.project)
    create(:feature_intent_issue, feature_intent: confidence_feature, issue: issue,
      release_state: "held", release_error: "Material prerequisite coverage has not been confirmed.")
    approval_feature = create(:feature_intent, project: issue.project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: approval_feature, issue: issue)

    hold = described_class.call(issue: issue)

    expect(hold.code).to eq("feature_not_released")
  end
end
