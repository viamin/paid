# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::ResolveQuestion do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:design_revision) { "a" * 40 }
  let(:acceptance_revision) { "acceptance-1" }
  let(:checkpoint) do
    create(:project_delegation_checkpoint, project:, issue:, design_revision:, acceptance_revision:)
  end
  let(:settled) do
    create(:project_delegation_settlement, checkpoint:, decision: "settled",
      answers: [ { "key" => "retention", "choice" => "30 days" } ])
  end

  def resolve(group_key: "retention", design: design_revision, acceptance: acceptance_revision,
    reason: nil, evidence: [])
    described_class.call(project:, issue:, group_key:, design_revision: design,
      acceptance_revision: acceptance, reason:, evidence:)
  end

  describe "a question settled at the current revisions" do
    it "returns the settled answer instead of asking again" do
      settled

      result = resolve

      expect(result).to be_settled
      expect(result).not_to be_stale
      expect(result.answer).to include("key" => "retention", "choice" => "30 days")
      expect(result.decision).to eq("settled")
    end

    it "does not re-ask when downstream work reaches another phase" do
      settled
      first = resolve
      second = resolve

      expect(first).to be_settled
      expect(second).to be_settled
      expect(second).not_to be_redecision
    end

    it "does not re-ask even when a conflict is claimed without a revision change" do
      settled

      result = resolve(reason: "invalidates", evidence: %w[new-evidence])

      expect(result).to be_settled
      expect(result).not_to be_stale
      expect(result).not_to be_redecision
    end
  end

  describe "a question settled at a superseded revision" do
    it "keeps the answer binding without a qualifying conflict" do
      settled

      result = resolve(design: "b" * 40, reason: "phase_change")

      expect(result).to be_settled
      expect(result).to be_stale
      expect(result).not_to be_redecision
    end

    it "keeps the answer binding when a conflict lacks supporting evidence" do
      settled

      result = resolve(design: "b" * 40, reason: "conflicts")

      expect(result).to be_settled
      expect(result).not_to be_redecision
    end

    it "routes a focused re-decision when new evidence materially expands the settled revision" do
      settled

      result = resolve(design: "b" * 40, acceptance: "acceptance-2",
        reason: "materially_expands", evidence: %w[issue-4880])

      expect(result).to be_redecision
      expect_focused_decision(result.focused_decision)
    end

    it "routes conflicts and invalidation reasons as focused re-decisions" do
      settled

      expect(resolve(design: "b" * 40, reason: "conflicts", evidence: %w[e1])).to be_redecision
      expect(resolve(design: "b" * 40, reason: "invalidates", evidence: %w[e1])).to be_redecision
    end

    it "names only the smallest affected question and leaves other groups settled" do
      checkpoint = create(:project_delegation_checkpoint, project:, issue:, design_revision:,
        acceptance_revision:, groups: [ retention_group, format_group ])
      create(:project_delegation_settlement, checkpoint:, decision: "settled",
        answers: [ { "key" => "retention", "choice" => "30 days" }, { "key" => "format", "choice" => "CSV" } ])

      decision = resolve(group_key: "retention", design: "b" * 40,
        reason: "conflicts", evidence: %w[e1]).focused_decision

      expect(decision["group_key"]).to eq("retention")
      expect(decision.keys).not_to include("groups")
      expect(resolve(group_key: "format", design: "b" * 40)).to be_settled
    end
  end

  describe "questions without a settlement" do
    it "reports a planned group as awaiting human settlement" do
      checkpoint

      result = resolve

      expect(result).to be_pending_settlement
      expect(result.group).to include("key" => "retention")
      expect(result).to be_needs_human
    end

    it "reports an unplanned question as needing a human decision" do
      checkpoint

      result = resolve(group_key: "brand-new")

      expect(result).to be_unplanned
      expect(result).to be_needs_human
    end

    it "keeps a superseded settlement authoritative across later checkpoints that drop the group" do
      settled
      create(:project_delegation_checkpoint, project:, issue:, design_revision: "c" * 40,
        acceptance_revision: "acceptance-3", groups: [ format_group ])

      result = resolve(design: "c" * 40, acceptance: "acceptance-3")

      expect(result).to be_settled
      expect(result.answer).to include("choice" => "30 days")
      expect(result.settlement.design_revision).to eq(design_revision)
    end
  end

  it "rejects a blank group key" do
    expect { resolve(group_key: " ") }.to raise_error(ArgumentError, /group_key/)
  end

  it "rejects blank revisions" do
    expect { resolve(design: "") }.to raise_error(ArgumentError, /design_revision/)
    expect { resolve(acceptance: nil) }.to raise_error(ArgumentError, /acceptance_revision/)
  end

  def expect_focused_decision(decision)
    expect(decision).to include(
      "group_key" => "retention",
      "question" => "How long should completed exports be retained?",
      "recommendation" => "Retain exports for 30 days with a storage cap.",
      "consequences" => "Longer retention increases storage cost and can surface stale exports.",
      "prior_decision" => "settled",
      "prior_answer" => "30 days",
      "reason" => "materially_expands",
      "evidence" => %w[issue-4880],
      "next_action" => "human_decision"
    )
    expect(decision["revision_delta"]["design"]).to eq("settled" => design_revision, "current" => "b" * 40)
    expect(decision["revision_delta"]["acceptance"]).to eq(
      "settled" => acceptance_revision, "current" => "acceptance-2"
    )
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
      "recommendation" => "CSV with a stable header contract.",
      "alternatives" => [ { "label" => "JSON", "tradeoff" => "Larger payloads." } ],
      "consequences" => "The chosen format becomes a public contract.",
      "affected_scope" => %w[exports api],
      "evidence" => %w[docs/exports.md]
    }
  end
end
