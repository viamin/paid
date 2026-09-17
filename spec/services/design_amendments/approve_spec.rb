# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-004
RSpec.describe DesignAmendments::Approve do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:actor) { create(:user, account: project.account) }
  let(:amendment) { create(:design_amendment, feature_intent: feature, project: project) }

  it "records the human approval of the amended design PR head" do
    described_class.call(amendment: amendment, actor: actor, pr_head_sha: "designhead1")

    expect(amendment.reload).to be_approved
    expect(amendment.approved_pr_head_sha).to eq("designhead1")
    expect(amendment.approved_by).to eq(actor)
    expect(amendment.approved_at).to be_present
  end

  it "refuses to approve an already merged amendment" do
    amendment.update!(status: "merged", amended_revision: "newrev", merged_at: Time.current)

    expect {
      described_class.call(amendment: amendment, actor: actor, pr_head_sha: "designhead2")
    }.to raise_error(DesignAmendments::InvalidTransitionError)
  end
end
