# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Settle do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:user) { create(:user, :member, account:) }
  let(:checkpoint) { create(:project_delegation_checkpoint, project:) }
  let(:answers) { [ { "key" => "retention", "choice" => "30 days" } ] }

  it "records human answers bound to the checkpoint design and acceptance revision" do
    settlement = described_class.call(checkpoint:, user:, decision: "settled", answers:)

    expect(settlement).to be_persisted
    expect(settlement.decision).to eq("settled")
    expect(settlement.answers).to eq(answers)
    expect(settlement.design_revision).to eq(checkpoint.design_revision)
    expect(settlement.acceptance_revision).to eq(checkpoint.acceptance_revision)
    expect(settlement.settled_by).to eq(user)
  end

  it "audits the settlement with the bound revisions" do
    settlement = described_class.call(checkpoint:, user:, decision: "settled", answers:)

    event = account.account_activity_events.by_action("delegation_checkpoint.settled").last
    expect(event).to have_attributes(actor: user, subject: settlement)
    expect(event.metadata).to include(
      "decision" => "settled",
      "design_revision" => checkpoint.design_revision,
      "acceptance_revision" => checkpoint.acceptance_revision
    )
  end

  it "keeps prior settlements immutable while a newer settlement is appended" do
    first = described_class.call(checkpoint:, user:, decision: "rejected", answers: [])
    second = described_class.call(checkpoint:, user:, decision: "settled", answers:)

    expect(first.reload.answers).to eq([])
    expect(second).to be_persisted
    expect { first.update!(decision: "amended") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { first.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "allows amending a group with a note" do
    settlement = described_class.call(checkpoint:, user:, decision: "amended",
      answers: [ { "key" => "retention", "choice" => "7 days", "note" => "Storage cost is the priority." } ])

    expect(settlement.decision).to eq("amended")
    expect(settlement.answers.first).to include("note" => "Storage cost is the priority.")
  end

  it "requires an account member or project collaborator" do
    outsider = create(:user, :member, account: create(:account))

    expect {
      described_class.call(checkpoint:, user: outsider, decision: "settled", answers:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::PermissionDenied)
  end

  it "requires every group to be answered when settling" do
    checkpoint = create(:project_delegation_checkpoint, project:, groups: [ retention_group, format_group ])

    expect {
      described_class.call(checkpoint:, user:, decision: "settled", answers:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::InvalidAnswers, /format/)
  end

  it "rejects answers for groups that were not asked" do
    expect {
      described_class.call(checkpoint:, user:, decision: "settled",
        answers: [ { "key" => "unknown", "choice" => "yes" } ])
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::InvalidAnswers, /unknown/)
  end

  it "rejects duplicate answers for one group" do
    expect {
      described_class.call(checkpoint:, user:, decision: "settled",
        answers: answers + answers)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::InvalidAnswers, /retention/)
  end

  it "rejects an unsupported decision" do
    expect {
      described_class.call(checkpoint:, user:, decision: "postponed", answers:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::InvalidDecision)
  end

  it "rejects settling a superseded checkpoint" do
    checkpoint.supersede!

    expect {
      described_class.call(checkpoint:, user:, decision: "settled", answers:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Settle::InvalidState)
  end

  def retention_group
    {
      "key" => "retention",
      "topic" => "Export retention",
      "question" => "How long should completed exports be retained?",
      "recommendation" => "Retain exports for 30 days with a storage cap.",
      "alternatives" => [ { "label" => "7 days", "tradeoff" => "Lower storage cost." } ],
      "consequences" => "Longer retention increases storage cost and can surface stale exports.",
      "affected_scope" => %w[exports],
      "evidence" => %w[issue-4871]
    }
  end

  def format_group
    {
      "key" => "format",
      "topic" => "Export retention",
      "question" => "Which export format is the delivery contract?",
      "recommendation" => "CSV.",
      "alternatives" => [ { "label" => "JSON", "tradeoff" => "Larger." } ],
      "consequences" => "The chosen format becomes a public contract.",
      "affected_scope" => %w[exports],
      "evidence" => %w[docs/exports.md]
    }
  end
end
