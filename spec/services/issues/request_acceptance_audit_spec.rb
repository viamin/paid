# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestAcceptanceAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

  # @spec PARTIAL-CLOSEOUT-027
  it "queues one report-only audit and records its mode in the evidence snapshot" do
    create(:issue, :pull_request, project:, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(result.request.evidence).to include("continuation_mode" => "acceptance_audit")
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "reuses an open audit request rather than queueing duplicate work" do
    create(:issue, :pull_request, project:, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)

    first = described_class.call(issue:, actor: user)
    second = described_class.call(issue:, actor: user)

    expect(second.agent_run).to eq(first.agent_run)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-027
  it "refuses rather than reusing an open implementation continuation" do
    create(:issue, :pull_request, project:, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
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

  # @spec PARTIAL-CLOSEOUT-030
  it "explains the shared native-child admission gate instead of offering a denied audit" do
    create(:issue, :pull_request, project:, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
    create(:issue, project:, github_state: "open", parent_issue: issue, github_number: 4596)

    result = described_class.call(issue:, actor: user)

    expect(result.success?).to be(false)
    expect(result.code).to eq(:open_native_child)
    expect(result.message).to include("#4596")
    expect(issue.agent_runs).to be_empty
  end
end
