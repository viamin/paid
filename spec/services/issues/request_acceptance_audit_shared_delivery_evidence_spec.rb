# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestAcceptanceAudit do # @spec PARTIAL-CLOSEOUT-063
  let(:account) { create(:account) }
  let(:actor) { create(:user, :member, account:) }
  let(:project) do
    create(:project, account:, created_by: actor, owner: "acme", repo: "alpha")
  end
  let(:session) { create(:chat_session, account:, created_by: actor, project:) }
  let(:issue) do
    create(:issue, project:, github_state: "open", paid_state: "completed",
      no_code_required_at: nil)
  end
  let(:producer_issue) { create(:issue, project:) }
  let(:pull_request) do
    create(:issue, :pull_request, project:, parent_issue: producer_issue,
      github_number: 5371, github_state: "closed", pr_review_phase: "merged",
      github_html_url: "https://github.com/acme/alpha/pull/5371",
      merged_commit_sha: "a" * 40)
  end

  def associate_shared_delivery
    Tools::ManageSharedDeliveryEvidence.new(user: actor, session:).call(
      project_id: project.id, issue_id: issue.id, pull_request_id: pull_request.id,
      action: "associate", confirmed: true
    )
  end

  def revoke_shared_delivery
    Tools::ManageSharedDeliveryEvidence.new(user: actor, session:).call(
      project_id: project.id, issue_id: issue.id, action: "revoke", confirmed: true
    )
  end

  def admit_audit
    associate_shared_delivery
    described_class.call(issue:, actor:)
  end

  it "admits one report-only audit from supported shared-delivery intake without replacement coding" do
    original_parent = pull_request.parent_issue

    request = admit_audit
    repeat = described_class.call(issue:, actor:)

    expect(Issues::CloseoutEvidence.call(issue)).to be_present
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project))
      .not_to include(issue)
    expect(request).to be_success
    expect(request.agent_run).to have_attributes(goal: "analyze_issue", status: "queued")
    expect(request.request.evidence).to include("continuation_mode" => "acceptance_audit")
    expect(repeat.agent_run).to eq(request.agent_run)
    expect(AgentRuns::RecheckIssueEligibility.call(request.agent_run)).to be(false)
    expect(issue.agent_runs.where(goal: "create_pr")).to be_empty
    expect(pull_request.reload.parent_issue).to eq(original_parent)
  end

  it "records an unknown result without inventing acceptance or closeout authority" do
    original_parent = pull_request.parent_issue
    request = admit_audit

    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(
      "gaps" => [],
      "criteria" => [ { "criterion" => "Confirm the shared delivery", "state" => "unknown" } ]
    )

    Activities::RunAcceptanceAuditActivity.new.execute(agent_run_id: request.agent_run.id)

    expect(request.agent_run.reload).to have_attributes(status: "completed")
    expect(request.request.reload.status).to eq("consumed")
    expect(PartialCloseouts::Assessment.call(issue).closeout_state).to eq("unmet_criteria")
    expect(described_class.call(issue:, actor:).code).to eq(:assessment_current)
    expect(issue.reload).to have_attributes(github_state: "open", paid_state: "completed",
      no_code_required_at: nil)
    expect(issue.agent_runs.where(goal: "create_pr")).to be_empty
    expect(issue.agent_runs.where(goal: "analyze_issue").count).to eq(1)
    expect(pull_request.reload.parent_issue).to eq(original_parent)
    expect(AutoResolveCloseoutJob).not_to have_been_enqueued
  end

  it "does not admit an audit without delivery evidence" do
    result = described_class.call(issue:, actor:)

    expect(result.code).to eq(:not_stalled)
    expect(result.agent_run).to be_nil
  end

  it "does not admit an audit after supported revocation" do
    associate_shared_delivery
    revoke_shared_delivery

    result = described_class.call(issue:, actor:)

    expect(result.code).to eq(:not_stalled)
    expect(result.agent_run).to be_nil
  end

  it "preserves a human hold instead of admitting an audit" do
    associate_shared_delivery
    issue.update!(paid_state: "manual_review")

    result = described_class.call(issue:, actor:)

    expect(result.code).to eq(:operator_pause)
    expect(result.agent_run).to be_nil
  end

  it "cancels an admitted audit when the pinned merge revision changes" do
    associate_shared_delivery
    request = described_class.call(issue:, actor:)

    pull_request.update!(merged_commit_sha: "b" * 40)

    expect(AgentRuns::RecheckIssueEligibility.call(request.agent_run)).to be(true)
    expect(request.agent_run.reload).to have_attributes(status: "cancelled")
    expect(request.request.reload.status).to eq("superseded")
    expect(issue.reload.github_state).to eq("open")
  end
end
