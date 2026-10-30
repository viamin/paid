# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestAcceptanceAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

  def merged_partial_pr
    create(:issue, :pull_request, project:, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
  end

  def resolve_current_evidence
    evidence = Issues::CloseoutEvidence.call(issue)
    issue.update!(closeout_resolved_at: 1.day.ago, closeout_resolution_digest: evidence.digest,
      closeout_resolved_by: user)
  end

  def record_acceptance_audit(criteria:, gaps: [])
    run = create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      pull_request_url: nil, pull_request_number: nil)
    assessment = PartialCloseouts::Assessment.snapshot(run, { "criteria" => criteria, "gaps" => gaps })
    run.update!(reconciliation: { "assessment" => assessment })
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "queues one report-only audit and records its mode in the evidence snapshot" do
    merged_partial_pr

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(result.request.evidence).to include("continuation_mode" => "acceptance_audit")
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "reuses an open audit request rather than queueing duplicate work" do
    merged_partial_pr

    first = described_class.call(issue:, actor: user)
    second = described_class.call(issue:, actor: user)

    expect(second.agent_run).to eq(first.agent_run)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "refuses rather than reusing an open implementation continuation" do
    merged_partial_pr
    implementation = Issues::RequestContinuation.call(
      issue:, actor: user, reason: "Continue the deferred implementation."
    )

    result = described_class.call(issue:, actor: user)

    expect(result.success?).to be(false)
    expect(result.code).to eq(:conflicting_open_request)
    expect(result.message).to include("implementation continuation")
    expect(issue.agent_runs.count).to eq(1)
    expect(implementation.request.reload.status).to eq("queued")
  end

  # @spec PARTIAL-CLOSEOUT-027 PARTIAL-CLOSEOUT-037
  it "queues a missing audit for legacy resolved evidence" do
    merged_partial_pr
    resolve_current_evidence

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run).to be_queued
    expect(issue.reload).not_to be_closeout_resolved
  end

  # @spec PARTIAL-CLOSEOUT-027 PARTIAL-CLOSEOUT-037
  it "queues a fresh audit when the recorded audit for legacy resolved evidence is stale" do
    merged_partial_pr
    resolve_current_evidence
    record_acceptance_audit(criteria: [ { "criterion" => "the work", "state" => "satisfied" } ])
    issue.update!(title: "Revised acceptance intent")

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run).to be_queued
    expect(issue.reload).not_to be_closeout_resolved
  end

  # @spec PARTIAL-CLOSEOUT-027 PARTIAL-CLOSEOUT-037
  it "queues an audit when satisfied criteria still contain recorded gaps" do
    merged_partial_pr
    resolve_current_evidence
    record_acceptance_audit(
      criteria: [ { "criterion" => "the work", "state" => "satisfied" } ],
      gaps: [ { "criterion" => "confirm the rollout", "kind" => "human" } ]
    )

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run).to be_queued
    expect(issue.reload).not_to be_closeout_resolved
  end
end
