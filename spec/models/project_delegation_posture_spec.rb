# frozen_string_literal: true

require "rails_helper"

# The durable project delegation posture record (RDR-080): one row per
# project, monotonic revisioning, and an immutable audit event for every
# lifecycle write.
# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
RSpec.describe ProjectDelegationPosture do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:owner) { create(:user, :owner, account:) }

  it "defaults to conservative with revision 1 and no delegated action classes" do
    posture = described_class.new(account: account, project: project)

    expect(posture).to be_valid
    expect(posture.level).to eq("conservative")
    expect(posture.revision).to eq(1)
    expect(posture.enabled_action_classes).to be_empty
    expect(posture).not_to be_delegating
  end

  it "allows only one posture row per project" do
    create(:project_delegation_posture, :conservative, project: project)

    duplicate = build(:project_delegation_posture, project: project)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:project]).to include("has already been taken")
  end

  it "rejects an unknown posture level" do
    posture = build(:project_delegation_posture, project: project, level: "fully_autonomous")

    expect(posture).not_to be_valid
    expect(posture.errors[:level]).to include("is not a supported delegation posture")
  end

  it "rejects a posture scoped to another account's project or actor" do
    other_account = create(:account)
    other_project = create(:project, account: other_account)

    posture = build(:project_delegation_posture, account: other_account, project: other_project,
      selected_by: create(:user, account: account))

    expect(posture).not_to be_valid
    expect(posture.errors[:selected_by]).to include("must belong to the account")
  end

  it "bumps the monotonic revision and records an audit event on selection" do
    posture = create(:project_delegation_posture, :conservative, project: project, selected_by: nil)

    posture.select!(level: described_class::DELEGATING_LEVEL, user: owner)

    expect(posture.reload).to have_attributes(
      level: "bounded_delivery",
      selected_by: owner,
      revision: 2,
      policy_signature: be_present
    )
    expect(posture).to be_delegating
    event = account.account_activity_events.by_action("project_delegation.selected").last
    expect(event).to have_attributes(actor: owner, subject: posture)
    expect(event.metadata).to include("level" => "bounded_delivery", "revision" => 2)
  end

  it "marks a held posture as not delegating and records the hold audit event" do
    posture = create(:project_delegation_posture, project: project)

    posture.hold!(user: owner, reason: "pending security review")

    expect(posture.reload).to be_held
    expect(posture).not_to be_delegating
    expect(posture.revision).to eq(2)
    event = account.account_activity_events.by_action("project_delegation.held").last
    expect(event.metadata).to include("reason" => "pending security review")
  end

  it "keeps a repeated hold idempotent" do
    posture = create(:project_delegation_posture, project: project)
    posture.hold!(user: owner, reason: "first")

    posture.hold!(user: owner, reason: "second")

    expect(posture.reload.revision).to eq(2)
    expect(posture.hold_reason).to eq("first")
    expect(account.account_activity_events.by_action("project_delegation.held").count).to eq(1)
  end

  it "releases a hold with another revision bump and audit event" do
    posture = create(:project_delegation_posture, project: project)
    posture.hold!(user: owner, reason: "paused")

    posture.release_hold!(user: owner)

    expect(posture.reload).not_to be_held
    expect(posture).to be_delegating
    expect(posture.revision).to eq(3)
    expect(account.account_activity_events.by_action("project_delegation.hold_released").last).to be_present
  end

  it "rolls back to conservative with a revision bump and its own audit event" do
    posture = create(:project_delegation_posture, project: project)

    posture.rollback!(user: owner, reason: "pilot reversal review")

    expect(posture.reload).to have_attributes(level: "conservative", revision: 2)
    expect(posture).not_to be_delegating
    event = account.account_activity_events.by_action("project_delegation.rolled_back").last
    expect(event).to have_attributes(actor: owner, subject: posture)
    expect(event.metadata).to include("reason" => "pilot reversal review", "from_level" => "bounded_delivery")
  end

  it "never lowers the revision across repeated writes" do
    posture = create(:project_delegation_posture, project: project)

    posture.hold!(user: owner)
    posture.release_hold!(user: owner)
    posture.rollback!(user: owner)

    expect(posture.reload.revision).to eq(4)
  end
end
