# frozen_string_literal: true

require "rails_helper"

# The durable delegation posture record: project-scoped, one row per project,
# carrying the selected level, monotonically increasing revision, the policy
# signature pinned at selection, and the enabled action classes.
# @spec PROJECT-DELEGATION-001
RSpec.describe ProjectDelegationPosture do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }

  it "defaults a new record to conservative with no delegated action classes" do
    record = described_class.new(account: account, project: project, policy_signature: "sig")

    expect(record).to be_valid
    expect(record.level).to eq("conservative")
    expect(record.enabled_action_classes).to eq([])
  end

  it "rejects an unknown level" do
    record = described_class.new(account: account, project: project, level: "autonomous",
      policy_signature: "sig")

    expect(record).not_to be_valid
    expect(record.errors[:level]).to include("is not a supported delegation posture")
  end

  # @spec PROJECT-DELEGATION-001
  it "rejects unknown levels when writes bypass model validation" do
    record = create(:project_delegation_posture, project: project)

    expect { record.update_column(:level, "autonomous") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_project_delegation_postures_level/)
  end

  it "rejects action classes outside the delegated vocabulary" do
    record = described_class.new(account: account, project: project, level: "bounded_delivery",
      enabled_action_classes: [ "release", "deployment" ], policy_signature: "sig")

    expect(record).not_to be_valid
    expect(record.errors[:enabled_action_classes]).to include("contains action classes bounded_delivery does not delegate")
  end

  it "requires conservative to delegate nothing" do
    record = described_class.new(account: account, project: project, level: "conservative",
      enabled_action_classes: [ "technical_stop_recovery" ], policy_signature: "sig")

    expect(record).not_to be_valid
    expect(record.errors[:enabled_action_classes]).to include("conservative delegates no action classes")
  end

  it "rejects an account that does not match the project" do
    record = described_class.new(account: create(:account), project: project,
      policy_signature: "sig")

    expect(record).not_to be_valid
    expect(record.errors[:account]).to include("must match the project")
  end

  it "rejects a selector outside the account" do
    record = described_class.new(account: account, project: project,
      selected_by: create(:user), policy_signature: "sig")

    expect(record).not_to be_valid
    expect(record.errors[:selected_by]).to include("must belong to the account")
  end

  it "keeps one posture row per project" do
    create(:project_delegation_posture, project: project)
    duplicate = build(:project_delegation_posture, project: project)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:project]).to include("has already been configured")
  end
end
