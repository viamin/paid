# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Open do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  before do
    issue.update!(needs_input_questions: [ "What should the default window be?" ])
  end

  it "persists one pending checkpoint bound to the current revisions" do
    checkpoint = described_class.call(project: project, issue: issue, actor: user)

    expect(checkpoint).to be_persisted
    expect(checkpoint).to be_pending
    expect(checkpoint.account).to eq(account)
    expect(checkpoint.design_revision).to be_present
    expect(checkpoint.acceptance_revision).to start_with("criteria:")
    expect(checkpoint.question_groups).to contain_exactly(
      hash_including("question" => "What should the default window be?", "key" => start_with("clarifying:"))
    )
  end

  it "publishes exactly one blocking Inbox request with the grouped questions" do
    checkpoint = described_class.call(project: project, issue: issue)

    notification = Notification.find_by(account: account, subject: issue, source: described_class::NOTIFICATION_SOURCE)
    expect(notification).to be_blocking
    expect(notification.metadata).to include(
      "checkpoint_id" => checkpoint.id,
      "groups" => contain_exactly(hash_including("question" => "What should the default window be?"))
    )
  end

  it "is idempotent while the plan and revisions are current" do
    first = described_class.call(project: project, issue: issue)
    second = described_class.call(project: project, issue: issue)

    expect(second.id).to eq(first.id)
    expect(issue.delegation_intent_checkpoints.count).to eq(1)
  end

  it "supersedes a stale pending checkpoint when the revision moves" do
    first = described_class.call(project: project, issue: issue)
    issue.update!(body: "A changed body moves the intent revision.")

    second = described_class.call(project: project, issue: issue)

    expect(first.reload).to be_superseded if first.id != second.id
    expect(second).to be_pending
    expect(second.design_revision).not_to eq(first.design_revision)
    expect(issue.delegation_intent_checkpoints.pending.count).to eq(1)
  end

  it "returns nil without a checkpoint when nothing material is known" do
    issue.update!(needs_input_questions: nil)

    expect(described_class.call(project: project, issue: issue)).to be_nil
    expect(issue.delegation_intent_checkpoints).to be_empty
  end
end
