# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-010
RSpec.describe ProjectDelegationHold do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:user) { create(:user, account:) }
  let(:hold) { create(:project_delegation_hold, project:, held_by: user) }

  it "requires a reason and a supported status" do
    expect(build(:project_delegation_hold, project:, reason: nil)).not_to be_valid
    expect(build(:project_delegation_hold, project:, status: "paused")).not_to be_valid
  end

  it "rejects a hold whose account does not match the project" do
    other_project = create(:project)

    hold = build(:project_delegation_hold, project: other_project, account:)

    expect(hold).not_to be_valid
    expect(hold.errors[:account]).to include("must match the project")
  end

  it "rejects an actor from another account" do
    hold = build(:project_delegation_hold, project:, held_by: create(:user))

    expect(hold).not_to be_valid
    expect(hold.errors[:held_by]).to include("must belong to the account")
  end

  it "records the release and its actor" do
    hold = create(:project_delegation_hold, project:, held_by: user)

    expect(hold.release!(user:)).to be(true)
    expect(hold.reload).to have_attributes(status: "released", released_by: user)
    expect(hold.released_at).to be_present
  end

  it "does not release a hold twice" do
    hold = create(:project_delegation_hold, project:, held_by: user)
    hold.release!(user:)

    expect(hold.release!(user:)).to be(false)
    expect(hold.reload.status).to eq("released")
  end

  it "records the release in the audit history" do
    hold = create(:project_delegation_hold, project:, held_by: user)

    hold.release!(user:)

    event = account.account_activity_events.by_action("project_delegation.hold_released").last
    expect(event).to have_attributes(actor: user, subject: hold)
  end

  it "keeps only one active hold per project" do
    create(:project_delegation_hold, project:, held_by: user)

    expect { create(:project_delegation_hold, project:, held_by: user) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a new hold after the previous one was released" do
    hold = create(:project_delegation_hold, project:, held_by: user)
    hold.release!(user:)

    expect { create(:project_delegation_hold, project:, held_by: user) }.not_to raise_error
  end

  it "is destroyed with its project" do
    hold

    project.destroy!

    expect(described_class.exists?(hold.id)).to be(false)
  end

  it "is destroyed with its account" do
    hold

    account.destroy!

    expect(described_class.exists?(hold.id)).to be(false)
  end
end
