# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-023 @spec FEATURE-APPROVAL-024 @spec CONFIDENCE-DELIVERY-014 @spec CONFIDENCE-DELIVERY-015
RSpec.describe FeatureIntents::RunAdmission do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  it "holds an issue linked to a feature that has not been released" do
    feature = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.reason).to include("not released")
  end

  it "admits a released feature only at its approved repository revision" do
    revision = "a" * 40
    feature = create(:feature_intent, project: project, approved_design_revision: revision)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(result.revision).to eq(revision)
  end

  it "fails closed when a released feature has no recorded revision" do
    feature = create(:feature_intent, project: project, approved_design_revision: nil)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "fails closed for confidence-driven work until its complete delivery integration exists" do
    feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.reason).to include("not available")
  end

  it "keeps mixed-policy features on their own admission contracts" do # @spec CONFIDENCE-DELIVERY-001
    approval_issue = create(:issue, project: project)
    approval_feature = create(:feature_intent, project: project)
    confidence_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: approval_feature, issue: approval_issue)
    create(:feature_intent_issue, feature_intent: confidence_feature, issue: issue)

    expect(described_class.call(issue: approval_issue)).to be_allowed
    expect(described_class.call(issue: issue)).not_to be_allowed
  end
end
