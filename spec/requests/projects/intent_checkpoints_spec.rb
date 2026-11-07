# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe "Projects::IntentCheckpoints" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:checkpoint) do
    issue.update!(needs_input_questions: [ "What should the default window be?" ])
    ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue, actor: user)
  end

  before do
    sign_in user
    user.add_role(:member, account)
  end

  def settle_path(for_checkpoint = checkpoint)
    settle_project_intent_checkpoint_path(project, for_checkpoint)
  end

  it "settles the grouped questions for an authorized project member" do
    group_key = checkpoint.question_groups.first.fetch("key")

    expect {
      post settle_path, params: {
        disposition: "settled",
        answers: [ { group_key: group_key, answer: "7 days." } ]
      }
    }.to change(DelegationIntentSettlement, :count).by(1)

    settlement = DelegationIntentSettlement.last
    expect(settlement.settled_by).to eq(user)
    expect(settlement.design_revision).to eq(checkpoint.design_revision)
    expect(response).to redirect_to(project_path(project))
  end

  it "rejects the group without answers" do
    expect {
      post settle_path, params: { disposition: "rejected" }
    }.to change(DelegationIntentSettlement, :count).by(1)

    expect(DelegationIntentSettlement.last.rejected?).to be(true)
  end

  it "refuses settlement for a user outside the account" do
    outsider = create(:user)
    sign_in outsider

    expect {
      post settle_path, params: {
        disposition: "settled",
        answers: [ { group_key: checkpoint.question_groups.first.fetch("key"), answer: "7 days." } ]
      }
    }.not_to change(DelegationIntentSettlement, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "scopes checkpoints to the project" do
    other_project = create(:project, account: account)

    expect {
      post settle_project_intent_checkpoint_path(other_project, checkpoint), params: { disposition: "rejected" }
    }.not_to change(DelegationIntentSettlement, :count)

    expect(response).to have_http_status(:not_found)
    expect(checkpoint.reload).to be_pending
  end
end
