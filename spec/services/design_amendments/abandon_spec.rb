# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-004
RSpec.describe DesignAmendments::Abandon do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project, approved_design_revision: "oldrev") }
  let(:amendment) { create(:design_amendment, feature_intent: feature, project: project) }

  it "abandons the amendment and returns the feature to released under the prior revision" do
    feature.revise!

    described_class.call(amendment: amendment)

    expect(amendment.reload).to be_abandoned
    expect(feature.reload).to be_released
    expect(feature.approved_design_revision).to eq("oldrev")
  end

  it "refuses to abandon a merged amendment" do
    amendment.update!(status: "merged", amended_revision: "newrev", merged_at: Time.current)

    expect {
      described_class.call(amendment: amendment)
    }.to raise_error(DesignAmendments::InvalidTransitionError)
  end
end
