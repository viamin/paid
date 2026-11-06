# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::Settlement do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:checkpoint) { create(:project_delegation_checkpoint, project:) }

  it "has a valid factory bound to the checkpoint revisions" do
    settlement = build(:project_delegation_settlement, checkpoint:)

    expect(settlement).to be_valid
    expect(settlement.design_revision).to eq(checkpoint.design_revision)
    expect(settlement.acceptance_revision).to eq(checkpoint.acceptance_revision)
  end

  it "rejects an unsupported decision" do
    settlement = build(:project_delegation_settlement, checkpoint:, decision: "postponed")

    expect(settlement).not_to be_valid
    expect(settlement.errors[:decision]).to include("is not included in the list")
  end

  it "rejects answers for groups that were not asked" do
    settlement = build(:project_delegation_settlement, checkpoint:,
      answers: [ { "key" => "unknown", "choice" => "yes" } ])

    expect(settlement).not_to be_valid
    expect(settlement.errors[:answers]).to include(/unknown/)
  end

  it "rejects answers without a choice" do
    settlement = build(:project_delegation_settlement, checkpoint:,
      answers: [ { "key" => "retention", "choice" => " " } ])

    expect(settlement).not_to be_valid
    expect(settlement.errors[:answers]).to include(/retention/)
  end

  it "rejects duplicate answers for one group" do
    settlement = build(:project_delegation_settlement, checkpoint:,
      answers: [ { "key" => "retention", "choice" => "30 days" }, { "key" => "retention", "choice" => "7 days" } ])

    expect(settlement).not_to be_valid
    expect(settlement.errors[:answers]).to include(/retention/)
  end

  it "requires full group coverage when the decision is settled" do
    settlement = build(:project_delegation_settlement, checkpoint:, decision: "settled", answers: [])

    expect(settlement).not_to be_valid
    expect(settlement.errors[:answers]).to include(/retention/)
  end

  it "allows a rejection without answers" do
    settlement = build(:project_delegation_settlement, checkpoint:, decision: "rejected", answers: [])

    expect(settlement).to be_valid
  end

  it "is immutable once persisted" do
    settlement = create(:project_delegation_settlement, checkpoint:)

    expect(settlement).to be_readonly
    expect { settlement.update!(decision: "rejected") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { settlement.touch }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { settlement.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "keeps the settlement inside the checkpoint account" do
    outsider = create(:user, account: create(:account))

    settlement = build(:project_delegation_settlement, checkpoint:, settled_by: outsider)

    expect(settlement).not_to be_valid
    expect(settlement.errors[:settled_by]).to include("must belong to the account")
  end

  it "keeps the settlement attached to the checkpoint's project and account" do
    other_project = create(:project, account:)
    settlement = build(:project_delegation_settlement, checkpoint:, project: other_project)

    expect(settlement).not_to be_valid
    expect(settlement.errors[:project]).to include("must match the checkpoint")
  end
end
