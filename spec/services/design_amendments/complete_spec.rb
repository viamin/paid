# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-004
RSpec.describe DesignAmendments::Complete do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project, approved_design_revision: "oldrev") }
  let(:actor) { create(:user, account: project.account) }
  let(:amendment) { create(:design_amendment, feature_intent: feature, project: project) }

  it "refuses to record a merged revision without a recorded human approval" do
    expect {
      described_class.call(amendment: amendment, merged_revision: "newrev")
    }.to raise_error(DesignAmendments::NotApprovedError)
  end

  it "refuses when the merged revision equals the superseded revision" do
    DesignAmendments::Approve.call(amendment: amendment, actor: actor, pr_head_sha: "designhead1")

    expect {
      described_class.call(amendment: amendment, merged_revision: "oldrev")
    }.to raise_error(DesignAmendments::NotApprovedError)
  end

  it "advances the approved revision, releases the feature, and evaluates impact" do
    DesignAmendments::Approve.call(amendment: amendment, actor: actor, pr_head_sha: "designhead1")
    allow(DesignAmendments::EvaluateImpact).to receive(:call).and_call_original

    described_class.call(amendment: amendment, merged_revision: "newrev")

    expect(amendment.reload).to be_merged
    expect(amendment.amended_revision).to eq("newrev")
    expect(feature.reload).to be_released
    expect(feature.approved_design_revision).to eq("newrev")
    expect(feature.approved_revision_recorded_at).to be_present
    expect(DesignAmendments::EvaluateImpact).to have_received(:call).with(amendment: amendment)
  end

  it "leaves the feature revising when impact evaluation is not possible yet" do
    # EvaluateImpact is invoked by Complete; a failure inside it must not
    # strand the feature in an inconsistent, silently-approved state.
    feature.revise!
    DesignAmendments::Approve.call(amendment: amendment, actor: actor, pr_head_sha: "designhead1")
    allow(DesignAmendments::EvaluateImpact).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(amendment))

    expect {
      described_class.call(amendment: amendment, merged_revision: "newrev")
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(feature.reload).to be_revising
    expect(feature.approved_design_revision).to eq("oldrev")
    expect(amendment.reload).not_to be_merged
  end
end
