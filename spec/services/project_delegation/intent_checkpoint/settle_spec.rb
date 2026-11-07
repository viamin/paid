# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Settle do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:checkpoint) do
    issue.update!(needs_input_questions: [ "What should the default window be?" ])
    ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue, actor: user)
  end

  before { user.add_role(:member, account) }

  it "binds settled answers immutably to the checkpoint's design and acceptance revisions" do
    settlement = described_class.call(
      checkpoint: checkpoint, actor: user, disposition: "settled",
      answers: [ { "group_key" => checkpoint.question_groups.first.fetch("key"), "answer" => "7 days." } ]
    )

    expect(settlement).to be_persisted
    expect(settlement.design_revision).to eq(checkpoint.design_revision)
    expect(settlement.acceptance_revision).to eq(checkpoint.acceptance_revision)
    expect(settlement.settled_by).to eq(user)
    expect(checkpoint.reload).to be_settled
  end

  it "records an audit event and resolves the Inbox request" do
    expect {
      described_class.call(
        checkpoint: checkpoint, actor: user, disposition: "settled",
        answers: [ { "group_key" => checkpoint.question_groups.first.fetch("key"), "answer" => "7 days." } ]
      )
    }.to change(AccountActivityEvent, :count).by(1)

    notification = Notification.find_by(account: account, subject: issue,
      source: ProjectDelegation::IntentCheckpoint::Open::NOTIFICATION_SOURCE)
    expect(notification.resolved_at).to be_present
  end

  it "records a rejection with no answers and keeps the questions human decisions" do
    settlement = described_class.call(checkpoint: checkpoint, actor: user, disposition: "rejected")

    expect(settlement.rejected?).to be(true)
    expect(settlement.answers).to be_empty
    expect(checkpoint.reload).to be_rejected
  end

  it "records amendments against the bound revision" do
    settlement = described_class.call(
      checkpoint: checkpoint, actor: user, disposition: "amended",
      answers: [ { "group_key" => checkpoint.question_groups.first.fetch("key"),
                   "amendment" => "Use 30 days instead of the recommendation." } ]
    )

    expect(settlement.amended?).to be(true)
    expect(settlement.answers.first).to include("amendment" => "Use 30 days instead of the recommendation.")
  end

  it "rejects settlement of a checkpoint that is no longer pending" do
    described_class.call(checkpoint: checkpoint, actor: user, disposition: "rejected")

    expect {
      described_class.call(checkpoint: checkpoint, actor: user, disposition: "settled")
    }.to raise_error(described_class::NotPending)
  end

  it "rejects actors without project settlement authority" do
    outsider = create(:user)

    expect {
      described_class.call(
        checkpoint: checkpoint, actor: outsider, disposition: "settled",
        answers: [ { "group_key" => checkpoint.question_groups.first.fetch("key"), "answer" => "7 days." } ]
      )
    }.to raise_error(described_class::PermissionDenied)
  end

  it "rejects malformed settlements" do
    key = checkpoint.question_groups.first.fetch("key")

    expect { described_class.call(checkpoint: checkpoint, actor: user, disposition: "finalized") }
      .to raise_error(described_class::InvalidSettlement)
    expect { described_class.call(checkpoint: checkpoint, actor: user, disposition: "settled") }
      .to raise_error(described_class::InvalidSettlement)
    expect { described_class.call(checkpoint: checkpoint, actor: user, disposition: "rejected", answers: [ { "group_key" => key, "answer" => "x" } ]) }
      .to raise_error(described_class::InvalidSettlement)
    expect {
      described_class.call(checkpoint: checkpoint, actor: user, disposition: "settled",
        answers: [ { "group_key" => "claim:unknown", "answer" => "x" } ])
    }.to raise_error(described_class::InvalidSettlement)
  end
end
