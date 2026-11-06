# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordSourceClosureRecoveryActivity do # @spec PARTIAL-CLOSEOUT-043
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:agent_run) do
    create(:agent_run, :running, project: project, issue: issue, goal: "create_pr",
      branch_name: "agent/issue-7", result_commit_sha: "abc123def456")
  end

  before do
    error = Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
      category: "timeout")
    PartialCloseouts::SourceClosureRecoveryState.record_attempt(agent_run, error: error,
      branch: agent_run.branch_name, commit_sha: agent_run.result_commit_sha)
  end

  it "parks the run in a durable waiting state instead of failing it" do
    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:status]).to eq("waiting")
    expect(agent_run.reload.status).to eq("paused")
    expect(agent_run.error_message).to be_blank
  end

  it "keeps the pushed revision, the attempts, and the failure category" do
    activity.execute(agent_run_id: agent_run.id)

    state = PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)
    expect(state).to include(
      "step" => "assess_source_closure",
      "branch" => "agent/issue-7",
      "commit_sha" => "abc123def456",
      "attempts" => 1,
      "failure_category" => "timeout"
    )
    expect(state["next_retry_at"]).to be_present
  end
end
