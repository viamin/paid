# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::AutoAudit do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }

  before do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "queues one automatic report-only audit after merge and never repeats it for the same evidence" do
    first = described_class.call(issue:)

    expect(first.scheduled?).to be(true)
    expect(first.agent_run.goal).to eq("analyze_issue")
    expect(first.agent_run.auto_pick).to be(true)
    expect(first.agent_run.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")

    first.agent_run.update!(status: "completed", completed_at: Time.current)
    second = described_class.call(issue:)

    expect(second.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "does not replace an operator's audit for the same evidence generation" do
    manual = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
    manual.agent_run.update!(status: "completed", completed_at: Time.current)

    result = described_class.call(issue:)

    expect(result.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "does not retry a failed audit for the same evidence generation" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "failed", completed_at: Time.current)

    result = described_class.call(issue:)

    expect(result.code).to eq(:already_audited)
    expect(issue.agent_runs.count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "allows one new audit after a new merged PR changes the evidence generation" do
    first = described_class.call(issue:)
    first.agent_run.update!(status: "completed", completed_at: Time.current)
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 13,
      github_state: "closed", pr_review_phase: "merged")

    second = described_class.call(issue:)

    expect(second.scheduled?).to be(true)
    expect(second.agent_run.id).not_to eq(first.agent_run.id)
    expect(second.agent_run.continuation_request.evidence_digest)
      .not_to eq(first.agent_run.continuation_request.evidence_digest)
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "keeps a dependency-held closeout for an operator" do
    dependency = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue:)

    expect(result.code).to eq(:blocked)
    expect(issue.agent_runs).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-037
  it "does not bypass disabled auto-pick" do
    project.update!(auto_pick_enabled: false)

    result = described_class.call(issue:)

    expect(result.code).to eq(:automation_disabled)
    expect(issue.agent_runs).to be_empty
  end
end
