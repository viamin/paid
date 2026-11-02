# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Confirm do
  # @spec AUTO-PICK-QUEUE-019
  it "confirms a pending repair after synchronization removes the cycle" do
    _user, _cycle, run = cycle_run
    IssueDependency.delete_all

    result = described_class.call(agent_run: run)

    expect(result).to include("status" => "resolved", "reason" => "synchronization_confirmed")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "keeps a pending repair retryable while synchronization has not removed the cycle" do
    _user, _cycle, run = cycle_run

    result = described_class.call(agent_run: run)

    expect(result).to include("status" => "pending_sync", "reason" => "awaiting_github_synchronization")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "holds a changed cycle involving the repaired issues for operator review" do
    _user, cycle, run = cycle_run
    third = create(:issue, project: cycle.project, github_state: "open")
    source = Issue.find(cycle.effective_edges.first.from_id)
    target = Issue.find(cycle.effective_edges.first.to_id)
    IssueDependency.delete_all
    create_legacy_issue_dependency(issue: source, depends_on_issue: third)
    create_legacy_issue_dependency(issue: third, depends_on_issue: target)
    create_legacy_issue_dependency(issue: target, depends_on_issue: source)

    result = described_class.call(agent_run: run)

    expect(result).to include("status" => "needs_operator_action", "reason" => "graph_changed")
  end

  def cycle_run
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, :completed, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) },
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => { "status" => "pending_sync" } } })
    [ user, cycle, run ]
  end
end
