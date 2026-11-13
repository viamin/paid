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

  # @spec PARTIAL-CLOSEOUT-051
  it "audits through its own stale prerequisite while implementation remains held" do
    merged_partial_pr
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(AgentRuns::RecheckIssueEligibility.call(result.agent_run)).to be(false)
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).where(id: issue.id)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-051
  it "keeps implementation held by its own prerequisite without an audit request" do
    merged_partial_pr
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    result = Issues::RequestContinuation.call(issue:, actor: user, reason: "Build the remaining work")

    expect(result.code).to eq(:human_prerequisite_notification)
    expect(issue.agent_runs.where(goal: "create_pr")).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-051
  it "does not re-audit a current assessment through an unchanged prerequisite" do
    merged_partial_pr
    record_acceptance_audit(criteria: [ { "criterion" => "human review", "state" => "unmet" } ])
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    expect(described_class.call(issue:, actor: user).code).to eq(:human_prerequisite_notification)
  end

  # @spec PARTIAL-CLOSEOUT-051
  it "audits a stale human prerequisite after its external work resolves" do
    merged_partial_pr
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness")
    create(:issue, project: target_project, github_number: 517, github_state: "closed")
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [
        { "identity" => "external-517", "kind" => "external",
          "external_dependency" => { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 } },
        { "identity" => "human-review", "kind" => "human" }
      ] })

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(AgentRuns::RecheckIssueEligibility.call(result.agent_run)).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-051
  it "keeps a stale audit held while its external work is open" do
    merged_partial_pr
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness")
    create(:issue, project: target_project, github_number: 517, github_state: "open")
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [
        { "identity" => "external-517", "kind" => "external",
          "external_dependency" => { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 } },
        { "identity" => "human-review", "kind" => "human" }
      ] })

    expect(described_class.call(issue:, actor: user).code).to eq(:prerequisite_notification)
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "queues one report-only audit and records its mode in the evidence snapshot" do
    merged_partial_pr

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(result.request.evidence).to include("continuation_mode" => "acceptance_audit")
    expect(result.request.evidence).to include(
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "closeout_policy_signature" => nil
    )
    expect(result.request.evidence_digest).to eq(
      PartialCloseouts::Assessment.source_revision_for(
        issue,
        closeout_evidence: Issues::CloseoutEvidence.call(issue)
      )
    )
  end

  # @spec PROJECT-DELEGATION-009
  it "captures delegated closeout authority at audit admission" do
    merged_partial_pr
    project.update!(auto_merge_mode: "all")
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    create(:project_delegation_posture, project:, selected_by: user)

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.request.evidence["closeout_policy_signature"]).to eq(
      Automation::DelegatedActionAdmission.posture_signature_for(project:, action: "issue_closure")
    )
  end

  # @spec PARTIAL-CLOSEOUT-042 PARTIAL-CLOSEOUT-047
  it "binds the audit request to source and technical evidence freshness" do
    merged_partial_pr
    source_run = create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      pull_request_url: nil, pull_request_number: nil)
    source_run.update!(reconciliation: {
      TechnicalPrerequisites::Evidence::RECONCILIATION_KEY => { "status" => "completed" }
    })

    result = described_class.call(issue:, actor: user)

    expect(result.request.evidence_digest).to eq(
      PartialCloseouts::Assessment.source_revision_for(issue, technical_evidence: [])
    )
    expect(result.request.evidence.fetch("source_revision"))
      .to eq(PartialCloseouts::Assessment.source_revision_for(issue))
    expect(AgentRuns::RecheckIssueEligibility.call(result.agent_run)).to be(false)
    expect(result.agent_run.reload).to be_queued

    source_run.update!(reconciliation: source_run.reconciliation.deep_merge(
      TechnicalPrerequisites::Evidence::RECONCILIATION_KEY => { "status" => "unavailable" }
    ))

    expect(AgentRuns::RecheckIssueEligibility.call(result.agent_run)).to be(true)
    expect(result.agent_run.reload.status).to eq("cancelled")
    expect(result.agent_run.error_message).to include("technical evidence changed")
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
