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

  # @spec PARTIAL-CLOSEOUT-023 — defense-in-depth for already-persisted
  # assessments that pre-date the LLM-side schema validation, or that
  # escaped it on the legacy text path: a non-Hash `next_action` value
  # would otherwise NoMethodError on `String#to_h`, crashing every Inbox
  # render that hits the issue (#4208 review thread).
  it "treats a persisted non-Hash next_action as missing and infers a fallback" do
    pull_request
    run = create(:agent_run, :completed, project:, issue:, pull_request_number: pull_request.github_number)
    assessment = {
      "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
      "intent_revision" => described_class.intent_revision_for(issue),
      "assessed_at" => Time.current.iso8601,
      "criteria" => [ { "criterion" => "Measure latency", "state" => "satisfied" } ],
      "next_action" => "request a bounded audit"
    }
    run.update!(reconciliation: { "assessment" => assessment })

    result = described_class.call(issue)

    expect(result.next_action.fetch("kind")).to eq("fresh_audit")
    expect(result.next_action.fetch("explanation")).to be_present
  end

  # @spec PARTIAL-CLOSEOUT-023 — defense-in-depth: a `criteria` array that
  # contains a non-Hash entry would otherwise NoMethodError on
  # `String#merge`, crashing the Inbox pane and authorized chat context.
  it "skips non-Hash criteria entries instead of crashing the render" do
    pull_request
    run = create(:agent_run, :completed, project:, issue:, pull_request_number: pull_request.github_number)
    assessment = {
      "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
      "intent_revision" => described_class.intent_revision_for(issue),
      "assessed_at" => Time.current.iso8601,
      "criteria" => [ { "criterion" => "Measure latency", "state" => "satisfied" }, "wire dispatch" ]
    }
    run.update!(reconciliation: { "assessment" => assessment })

    expect { described_class.call(issue) }.not_to raise_error
    result = described_class.call(issue)
    expect(result.criteria.size).to eq(1)
    expect(result.criteria.first["criterion"]).to eq("Measure latency")
  end

  # @spec PARTIAL-CLOSEOUT-023 — pre-PR gaps-only assessments never had
  # `source_revision` / `intent_revision` recorded, so every legacy row is
  # stale on the digest mismatch alone — but nothing actually changed in
  # evidence or intent. The view must distinguish this from a genuine
  # revision change so operators get an actionable message instead of
  # contradictory copy ("no criterion-level assessment recorded" + "is
  # stale because evidence changed") right after deploy (#4208 review).
  it "is stale with no revision metadata recorded (legacy gaps-only assessment)" do
    pull_request
    run = create(:agent_run, :completed, project:, issue:, pull_request_number: pull_request.github_number)
    run.update!(reconciliation: {
      "assessment" => { "gaps" => [ { "criterion" => "Legacy gap", "kind" => "agent", "title" => "Ship it" } ] }
    })

    result = described_class.call(issue)

    expect(result.stale?).to be(true)
    expect(result.source_revision).to be_nil
    expect(result.intent_revision).to be_nil
  end
end
