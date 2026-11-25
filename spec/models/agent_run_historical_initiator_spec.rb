# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun do # @spec PARTIAL-CLOSEOUT-064 TENANT-ACCESS-003
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:) }
  let(:agent_run) { create(:agent_run, :queued, project:, issue:, initiating_user: member) }

  def move_requester
    agent_run
    member.add_role(:member, create(:account))
    Accounts::RemoveMembership.call(account:, membership: member.account_membership_for(account), actor: owner)
    agent_run.reload
  end

  it "rejects new cross-account initiation even with a cancelled status" do
    record = build(:agent_run, project:, issue:, initiating_user: create(:user), status: "cancelled")

    expect(record).not_to be_valid
    expect(record.errors[:initiating_user]).to be_present
  end

  it "does not resume a run using historical cross-account attribution" do
    move_requester

    expect(agent_run.update(status: "running", started_at: Time.current)).to be(false)
    expect(agent_run.errors[:initiating_user]).to be_present
    expect(agent_run.reload.status).to eq("queued")
  end

  it "does not reassign an initiator while cancelling a historical run" do
    move_requester

    expect(agent_run.update(status: "cancelled", initiating_user: create(:user))).to be(false)
    expect(agent_run.errors[:initiating_user]).to be_present
    expect(agent_run.reload.initiating_user_id).to eq(member.id)
  end
end
