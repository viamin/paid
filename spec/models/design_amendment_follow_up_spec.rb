# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-008
RSpec.describe DesignAmendmentFollowUp do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:amendment) { create(:design_amendment, feature_intent: feature, project: project, status: "merged") }
  let(:merged_pr) { create(:issue, :pull_request, project: project, github_state: "closed", pr_review_phase: "merged") }
  let(:actor) { create(:user, account: project.account) }

  it "records a human decision on the follow-up" do
    follow_up = create(:design_amendment_follow_up, design_amendment: amendment, issue: merged_pr)

    follow_up.resolve!(actor: actor, decision: "Ship a follow-up change under the amended design.")

    expect(follow_up).to be_resolved
    expect(follow_up.decided_by).to eq(actor)
    expect(follow_up.decided_at).to be_present
  end

  it "requires a decision and deciding human when resolved" do
    follow_up = build(:design_amendment_follow_up, design_amendment: amendment,
      issue: merged_pr, status: "resolved")

    expect(follow_up).not_to be_valid
    expect(follow_up.errors[:decision]).to be_present
  end
end
