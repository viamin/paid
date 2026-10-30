# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveCloseout do # @spec PARTIAL-CLOSEOUT-006
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive_messages(
      issue: Struct.new(:state).new("open"),
      update_issue: Struct.new(:state).new("closed")
    )
  end

  def merged_partial_pr(number:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
  end

  def accepted_audit
    run = create(:agent_run, :completed, project:, issue:)
    run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(run, {
      "criteria" => [ { "criterion" => "the work", "state" => "satisfied" } ], "gaps" => []
    }) })
  end

  def expect_revalidation_event(blocker:, evidence_digest:)
    event = account.account_activity_events.find_by!(action: "issue.closeout_revalidation_failed")
    expect(event).to have_attributes(actor: user, subject: issue)
    expect(event.metadata).to include(
      "reason" => "Merged PR #12 covers the remainder.", "evidence_digest" => evidence_digest, "blocker" => blocker
    )
  end

  it "records the actor, reason, and evidence generation and completes the issue" do
    merged_partial_pr(number: 12)
    accepted_audit
    digest = Issues::CloseoutEvidence.call(issue).digest

    result = described_class.call(issue: issue, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.success?).to be(true)
    issue.reload
    expect(issue.paid_state).to eq("completed")
    expect(issue.closeout_resolved_at).to be_present
    expect(issue.closeout_resolution_digest).to eq(digest)
    expect(issue.closeout_resolved_by).to eq(user)
    expect(issue.github_state).to eq("closed")
    expect(github_client).to have_received(:update_issue).with("acme/alpha", issue.github_number, state: "closed", state_reason: "completed")
  end

  it "performs GitHub reads and writes outside the database transaction" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    transaction_depth = ActiveRecord::Base.connection.open_transactions
    allow(github_client).to receive(:issue) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transaction_depth)
      Struct.new(:state).new("open")
    end
    allow(github_client).to receive(:update_issue) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transaction_depth)
      Struct.new(:state).new("closed")
    end

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result).to be_success
  end

  it "revokes continuation admission before releasing the lock for GitHub closure" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    allow(github_client).to receive(:update_issue) do
      continuation = Issues::RequestContinuation.call(issue: issue.reload, actor: user, reason: "Continue remaining work.")
      expect(continuation.code).to eq(:closeout_closing)
      Struct.new(:state).new("closed")
    end

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result).to be_success
    expect(issue.reload.closeout_closing_at).to be_nil
  end

  it "recovers an abandoned closing marker after its bounded lifetime" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    issue.update!(closeout_closing_at: Issue::CLOSEOUT_CLOSING_TTL.ago - 1.second)

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result).to be_success
    expect(issue.reload.closeout_closing_at).to be_nil
  end

  it "does not clear a replacement closing marker when an expired attempt finishes" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    replacement_marker = nil
    allow(github_client).to receive(:issue) do
      issue.update!(closeout_closing_at: Time.current)
      replacement_marker = issue.reload.closeout_closing_at
      raise GithubClient::Error, "timed out"
    end

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:github_failed)
    expect(issue.reload.closeout_closing_at).to eq(replacement_marker)
  end

  it "refuses closure while an agent run is already active" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    create(:agent_run, project:, issue:, status: "running")

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:open_prerequisites)
    expect(github_client).not_to have_received(:issue)
    expect(github_client).not_to have_received(:update_issue)
  end

  it "revalidates prerequisites after GitHub confirms closure" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    attempted_digest = Issues::CloseoutEvidence.call(issue).digest
    allow(github_client).to receive(:update_issue) do
      create(:notification, :error, account:, subject: issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)
      Struct.new(:state).new("closed")
    end

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:open_prerequisites)
    expect(result.message).to include("GitHub confirmed closure", "follow-up")
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(issue.closeout_resolved_at).to be_nil
    expect(issue.github_state).to eq("closed")
    expect(issue.closed_at).to be_present
    expect_revalidation_event(blocker: "open_prerequisites", evidence_digest: attempted_digest)
  end

  it "reconciles GitHub closure when acceptance evidence changes during the remote write" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    attempted_digest = Issues::CloseoutEvidence.call(issue).digest
    allow(github_client).to receive(:update_issue) do
      issue.update!(body: "Changed acceptance criteria")
      Struct.new(:state).new("closed")
    end

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:audit_pending)
    expect(result.message).to include("GitHub confirmed closure", "follow-up")
    expect(issue.reload).to have_attributes(github_state: "closed", paid_state: "in_progress")
    expect_revalidation_event(blocker: "audit_pending", evidence_digest: attempted_digest)
  end

  it "requires closeout evidence" do
    result = described_class.call(issue: issue, actor: user, reason: "done", client: github_client)

    expect(result.success?).to be(false)
    expect(result.code).to eq(:not_stalled)
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(issue.closeout_resolved_at).to be_nil
  end

  it "requires a reason" do
    merged_partial_pr(number: 12)
    accepted_audit

    result = described_class.call(issue: issue, actor: user, reason: " ", client: github_client)

    expect(result.code).to eq(:invalid_reason)
  end

  # @spec PARTIAL-CLOSEOUT-014 — the legacy hidden form reason is not a
  # specific rationale; submitting it unchanged must be refused so the
  # operator writes evidence-referencing text instead.
  it "refuses the legacy canned hidden reason" do
    merged_partial_pr(number: 12)
    accepted_audit

    result = described_class.call(issue: issue, actor: user, reason: "Operator attests the recorded closeout evidence completes ##{issue.github_number}.", client: github_client)

    expect(result.success?).to be(false)
    expect(result.code).to eq(:generic_reason)
    expect(result.message).to include("specific completion rationale")
    expect(issue.reload.paid_state).to eq("in_progress")
  end

  it "accepts an evidence-referencing rationale that is not the canned sentence" do
    merged_partial_pr(number: 12)
    accepted_audit

    result = described_class.call(
      issue: issue,
      actor: user,
      reason: "Merged PR #12 plus the recorded no-code declaration cover every acceptance criterion in the issue body.",
      client: github_client
    )

    expect(result.success?).to be(true)
  end

  it "records an audit event" do
    merged_partial_pr(number: 12)
    accepted_audit

    described_class.call(issue: issue, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    event = account.account_activity_events.where(action: "issue.closeout_resolved").last
    expect(event).to be_present
    expect(event.actor).to eq(user)
    expect(event.subject).to eq(issue)
  end

  # @spec PARTIAL-CLOSEOUT-006 — resolving complete revokes a queued continuation.
  it "supersedes an open continuation and cancels its queued run" do
    merged_partial_pr(number: 12)
    accepted_audit
    request = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
    run = create(:agent_run, project: project, issue: issue, continuation_request: request, goal: "create_pr", status: "queued")

    result = described_class.call(issue: issue, actor: user, reason: "The merged PR completes the issue.", client: github_client)

    expect(result).to be_success
    expect(issue.reload.paid_state).to eq("completed")
    expect(request.reload.status).to eq("superseded")
    expect(request.closure_reason).to eq("Continuation superseded: issue resolved as complete.")
    expect(run.reload.status).to eq("cancelled")
  end

  it "refuses a closed issue" do
    merged_partial_pr(number: 12)
    issue.update!(github_state: "closed", closed_at: Time.current)

    result = described_class.call(issue: issue.reload, actor: user, reason: "done", client: github_client)

    expect(result.success?).to be(false)
  end

  it "refuses closure until a current audit accepts every criterion" do # @spec PARTIAL-CLOSEOUT-037
    merged_partial_pr(number: 12)

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:audit_pending)
    expect(github_client).not_to have_received(:update_issue)
  end

  it "refuses closure while an external prerequisite notification remains open" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    dependency_project = create(:project, account:, owner: "viamin", repo: "agent-harness")
    create(:issue, project: dependency_project, github_number: 517, github_state: "open")
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [ {
        "identity" => "agent-harness-517", "kind" => "external",
        "external_dependency" => { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
      } ] })

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:open_prerequisites)
    expect(github_client).not_to have_received(:update_issue)
    expect(issue.reload.github_state).to eq("open")
  end

  it "routes synthetic scanner records to authoritative alert reconciliation" do # @spec PARTIAL-CLOSEOUT-006
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    merged_partial_pr(number: 12)
    accepted_audit

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the scanner finding.", client: github_client)

    expect(result.code).to eq(:scanner_managed)
    expect(result.message).to include("authoritative code-scanning snapshot")
    expect(github_client).not_to have_received(:issue)
    expect(github_client).not_to have_received(:update_issue)
    expect(issue.reload.github_state).to eq("open")
  end

  it "refuses to close an upstream issue through the project fork" do # @spec PARTIAL-CLOSEOUT-006 UPSTREAM-ISSUE-008
    project.update!(pr_target: "upstream", upstream_full_name: "upstream/alpha")
    merged_partial_pr(number: 12)
    accepted_audit

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:upstream_managed)
    expect(result.message).to include("directly on the upstream repository")
    expect(github_client).not_to have_received(:issue)
    expect(github_client).not_to have_received(:update_issue)
    expect(issue.reload.github_state).to eq("open")
    expect(issue.closeout_resolved_at).to be_nil
  end

  it "keeps the actionable item retryable when GitHub rejects closure" do # @spec PARTIAL-CLOSEOUT-037
    merged_partial_pr(number: 12)
    accepted_audit
    allow(github_client).to receive(:update_issue).and_raise(GithubClient::Error, "timeout")

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:github_failed)
    expect(result.message).to include("retry Close on GitHub")
    expect(issue.reload.github_state).to eq("open")
    expect(issue.closeout_closing_at).to be_nil
  end

  it "preserves an open continuation when GitHub rejects closure" do # @spec PARTIAL-CLOSEOUT-006
    merged_partial_pr(number: 12)
    accepted_audit
    request = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
    run = create(:agent_run, project: project, issue: issue, continuation_request: request, goal: "create_pr", status: "queued")
    request_status = request.status
    allow(github_client).to receive(:update_issue).and_raise(GithubClient::Error, "timeout")

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:github_failed)
    expect(request.reload.status).to eq(request_status)
    expect(run.reload.status).to eq("queued")
  end

  it "reconciles an observed GitHub closure without requesting closure again" do # @spec PARTIAL-CLOSEOUT-037
    merged_partial_pr(number: 12)
    accepted_audit
    allow(github_client).to receive(:issue).and_return(Struct.new(:state).new("closed"))

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result).to be_success
    expect(github_client).not_to have_received(:update_issue)
    expect(issue.reload.github_state).to eq("closed")
    expect(issue.paid_state).to eq("completed")
    expect(issue.closeout_resolved_by).to eq(user)
  end

  it "keeps the actionable item retryable when GitHub state is unavailable" do # @spec PARTIAL-CLOSEOUT-037
    merged_partial_pr(number: 12)
    accepted_audit
    allow(github_client).to receive(:issue).and_return(Object.new)

    result = described_class.call(issue:, actor: user, reason: "Merged PR #12 covers the remainder.", client: github_client)

    expect(result.code).to eq(:github_unavailable)
    expect(github_client).not_to have_received(:update_issue)
    expect(issue.reload.github_state).to eq("open")
  end
end
