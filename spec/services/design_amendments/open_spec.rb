# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-003
RSpec.describe DesignAmendments::Open do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }

  before do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
  end

  it "binds the amendment to the feature and its approved revision, and marks the feature revising" do
    amendment = described_class.call(
      feature_intent: feature,
      reason: "Approved scope must widen.",
      drift_evidence: { "changed_claims" => [ "Approved scope excludes imports" ] }
    )

    expect(amendment).to be_persisted
    expect(amendment.status).to eq("open")
    expect(amendment.superseded_revision).to eq(feature.approved_design_revision)
    expect(amendment.feature_intent).to eq(feature)
    expect(feature.reload).to be_revising
  end

  it "is gated by the approved_intent_amendments feature flag (default off)" do
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => false })

    expect {
      described_class.call(feature_intent: feature, reason: "Scope must widen.")
    }.to raise_error(DesignAmendments::DisabledError)
  end

  it "refuses to amend a feature that was never released" do
    feature.update!(status: "design_open")

    expect {
      described_class.call(feature_intent: feature, reason: "Not yet approved.")
    }.to raise_error(FeatureIntent::InvalidTransitionError)
  end
end
