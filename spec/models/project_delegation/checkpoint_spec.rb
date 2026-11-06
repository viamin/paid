# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::Checkpoint do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "has a valid factory with grouped material questions" do
    checkpoint = build(:project_delegation_checkpoint, project:)

    expect(checkpoint).to be_valid
    expect(checkpoint.groups.first).to include("key", "topic", "question", "recommendation",
      "alternatives", "consequences", "affected_scope", "evidence")
  end

  it "allows a feature-scoped checkpoint without an issue" do
    checkpoint = build(:project_delegation_checkpoint, project:, issue: nil)

    expect(checkpoint).to be_valid
  end

  it "requires design and acceptance revisions" do
    checkpoint = build(:project_delegation_checkpoint, project:, design_revision: nil, acceptance_revision: " ")

    expect(checkpoint).not_to be_valid
    expect(checkpoint.errors[:design_revision]).to include("can't be blank")
    expect(checkpoint.errors[:acceptance_revision]).to include("can't be blank")
  end

  it "rejects an unknown status" do
    checkpoint = build(:project_delegation_checkpoint, project:, status: "draft")

    expect(checkpoint).not_to be_valid
    expect(checkpoint.errors[:status]).to include("is not included in the list")
  end

  it "rejects groups missing the full presentation contract" do
    incomplete = valid_group.except("recommendation", "alternatives", "consequences",
      "affected_scope", "evidence")

    checkpoint = build(:project_delegation_checkpoint, project:, groups: [ incomplete ])

    expect(checkpoint).not_to be_valid
    expect(checkpoint.errors[:groups]).to include(/recommendation/)
    expect(checkpoint.errors[:groups]).to include(/alternatives/)
    expect(checkpoint.errors[:groups]).to include(/consequences/)
    expect(checkpoint.errors[:groups]).to include(/affected_scope/)
    expect(checkpoint.errors[:groups]).to include(/evidence/)
  end

  it "rejects alternatives without labels" do
    group = valid_group.merge("alternatives" => [ { "tradeoff" => "no label" } ])

    expect(build(:project_delegation_checkpoint, project:, groups: [ group ])).not_to be_valid
  end

  it "rejects duplicate group keys" do
    expect(build(:project_delegation_checkpoint, project:, groups: [ valid_group, valid_group ])).not_to be_valid
  end

  it "rejects an empty group set" do
    expect(build(:project_delegation_checkpoint, project:, groups: [])).not_to be_valid
  end

  it "keeps checkpoints in account/project scope" do
    other_project = create(:project, account: create(:account))
    checkpoint = build(:project_delegation_checkpoint, project:, account: other_project.account)

    expect(checkpoint).not_to be_valid
    expect(checkpoint.errors[:account]).to include("must match the project")
  end

  it "keeps the issue inside the project scope" do
    other_issue = create(:issue, project: create(:project, account:))

    checkpoint = build(:project_delegation_checkpoint, project:, issue: other_issue)

    expect(checkpoint).not_to be_valid
    expect(checkpoint.errors[:issue]).to include("must belong to the project")
  end

  it "supersedes an open checkpoint" do
    checkpoint = create(:project_delegation_checkpoint, project:)

    checkpoint.supersede!

    expect(checkpoint.reload.status).to eq("superseded")
    expect(described_class.open).not_to include(checkpoint)
  end

  def valid_group
    {
      "key" => "retention",
      "topic" => "Export retention",
      "question" => "How long should completed exports be retained?",
      "recommendation" => "Retain exports for 30 days with a storage cap.",
      "alternatives" => [ { "label" => "7 days", "tradeoff" => "Lower storage cost." } ],
      "consequences" => "Longer retention increases storage cost.",
      "affected_scope" => %w[exports],
      "evidence" => %w[issue-4871]
    }
  end
end
