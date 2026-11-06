# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Plan do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:design_revision) { "a" * 40 }
  let(:acceptance_revision) { "acceptance-1" }

  let(:questions) do
    [
      {
        key: "retention", topic: "Export retention",
        question: "How long should completed exports be retained?",
        recommendation: "Retain exports for 30 days with a storage cap.",
        alternatives: [ { label: "7 days", tradeoff: "Lower storage cost." } ],
        consequences: "Longer retention increases storage cost.",
        affected_scope: %w[exports], evidence: %w[issue-4871]
      },
      {
        key: "format", topic: "Export retention",
        question: "Which export format is the delivery contract?",
        recommendation: "CSV with a stable header contract.",
        alternatives: [ { label: "JSON", tradeoff: "Machine readable but larger." } ],
        consequences: "The chosen format becomes a public contract.",
        affected_scope: %w[exports api], evidence: %w[docs/exports.md]
      }
    ]
  end

  it "groups related material questions into one reviewable checkpoint" do
    checkpoint = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)

    expect(checkpoint).to be_persisted
    expect(checkpoint.status).to eq("open")
    expect(checkpoint.groups.map { |group| group["key"] }).to eq(%w[format retention])
    retention = checkpoint.groups.find { |group| group["key"] == "retention" }
    expect(retention).to include(
      "topic" => "Export retention",
      "question" => "How long should completed exports be retained?",
      "recommendation" => "Retain exports for 30 days with a storage cap.",
      "alternatives" => [ { "label" => "7 days", "tradeoff" => "Lower storage cost." } ],
      "consequences" => "Longer retention increases storage cost.",
      "affected_scope" => %w[exports],
      "evidence" => %w[issue-4871]
    )
  end

  it "records the proposed design and acceptance revision on the checkpoint" do
    checkpoint = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)

    expect(checkpoint.design_revision).to eq(design_revision)
    expect(checkpoint.acceptance_revision).to eq(acceptance_revision)
  end

  it "allows a feature-scoped checkpoint without an issue" do
    checkpoint = described_class.call(project:, design_revision:, acceptance_revision:, questions:)

    expect(checkpoint.issue).to be_nil
    expect(checkpoint).to be_persisted
  end

  it "refreshes the open checkpoint instead of duplicating it at the same revision" do
    first = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)
    revised = questions.drop(1)
    second = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions: revised)

    expect(second.id).to eq(first.id)
    expect(second.groups.map { |group| group["key"] }).to eq(%w[format])
    expect(ProjectDelegation::Checkpoint.count).to eq(1)
  end

  it "supersedes the open checkpoint when the revision changes" do
    first = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)

    second = described_class.call(project:, issue:, design_revision: "b" * 40,
      acceptance_revision: "acceptance-2", questions:)

    expect(first.reload.status).to eq("superseded")
    expect(second.status).to eq("open")
    expect(ProjectDelegation::Checkpoint.open).to contain_exactly(second)
  end

  it "fails closed when the scope was already settled at the same revision" do
    checkpoint = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)
    ProjectDelegation::IntentCheckpoint::Settle.call(
      checkpoint:, user: create(:user, :member, account:), decision: "settled",
      answers: checkpoint.groups.map { |group| { "key" => group["key"], "choice" => "recommended" } }
    )

    expect {
      described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::AlreadySettled, /focused re-decision/)
  end

  it "allows re-planning at the same revision after a human rejection" do
    checkpoint = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)
    ProjectDelegation::IntentCheckpoint::Settle.call(
      checkpoint:, user: create(:user, :member, account:), decision: "rejected", answers: []
    )

    replanned = described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions:)

    expect(replanned).to be_persisted
  end

  it "rejects a question missing required presentation fields" do
    incomplete = questions.first.except(:alternatives)

    expect {
      described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions: [ incomplete ])
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::InvalidQuestions, /retention.*alternatives/)
  end

  it "rejects unknown question fields" do
    unexpected = questions.first.merge(surprise: true)

    expect {
      described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions: [ unexpected ])
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::InvalidQuestions, /unknown field/)
  end

  it "rejects an empty question set" do
    expect {
      described_class.call(project:, issue:, design_revision:, acceptance_revision:, questions: [])
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::InvalidQuestions)
  end

  it "rejects blank revisions" do
    expect {
      described_class.call(project:, issue:, design_revision: "  ", acceptance_revision:, questions:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::InvalidRevision)
  end

  it "rejects an issue from another project" do
    other_issue = create(:issue, project: create(:project, account:))

    expect {
      described_class.call(project:, issue: other_issue, design_revision:, acceptance_revision:, questions:)
    }.to raise_error(ProjectDelegation::IntentCheckpoint::Plan::InvalidScope)
  end
end
