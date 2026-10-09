# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::Assessment do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project:, github_state: "open", body: "## Acceptance\n- Measure latency") }
  let(:pull_request) do
    create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged", parent_issue: issue)
  end

  # @spec PARTIAL-CLOSEOUT-023
  it "keeps a closed child unmet and marks the audit stale instead of inventing acceptance" do
    pull_request
    owner = create(:issue, project:, github_state: "closed", github_number: 902)
    run = create(:agent_run, :completed, project:, issue:, pull_request_number: pull_request.github_number)
    run.update!(reconciliation: {
      "assessment" => {
        "source_revision" => "old evidence", "intent_revision" => "old intent", "assessed_at" => 3.days.ago.iso8601,
        "criteria" => [ { "criterion" => "Measure latency", "state" => "unmet", "owner_issue_number" => owner.github_number } ],
        "classification" => "missing_measured_results"
      }
    })

    result = described_class.call(issue)

    expect(result.stale?).to be(true)
    expect(result.criteria.first.fetch("state")).to eq("unmet")
    expect(result.criteria.first.dig("owner", "open")).to be(false)
    expect(result.next_action.fetch("kind")).to eq("fresh_audit")
  end

  # @spec PARTIAL-CLOSEOUT-023
  it "uses persisted human prerequisites and an open owner without a render-time assessment" do
    pull_request
    owner = create(:issue, project:, github_state: "open", github_number: 903)
    run = create(:agent_run, :completed, project:, issue:, pull_request_number: pull_request.github_number)
    assessment = {
      "criteria" => [
        { "criterion" => "Measure latency", "state" => "unknown", "owner_issue_number" => owner.github_number,
          "prerequisite_kind" => "human", "prerequisite" => "Operator attaches production p95." }
      ],
      "classification" => "blocked_implementation", "next_action" => { "kind" => "wait_for_owner", "explanation" => "Owner is collecting evidence." }
    }
    run.update!(reconciliation: { "assessment" => described_class.snapshot(run, assessment) })

    result = described_class.call(issue)

    expect(result.stale?).to be(false)
    expect(result.criteria.first).to include("state" => "unknown", "prerequisite_kind" => "human")
    expect(result.criteria.first.dig("owner", "number")).to eq(owner.github_number)
    expect(result.next_action.fetch("kind")).to eq("wait_for_owner")
  end
end
