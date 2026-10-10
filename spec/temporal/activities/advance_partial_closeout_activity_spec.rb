# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AdvancePartialCloseoutActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:agent_run) do
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr",
      pull_request_number: 12, pull_request_url: "https://github.com/acme/alpha/pull/12",
      completed_at: 2.days.ago, reconciliation: { "assessment" => { "gaps" => [] } })
  end

  before do
    create(:issue, :pull_request, project: project, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "schedules a gap-free audit after the terminal source run is reconciled" do
    result = activity.execute(agent_run_id: agent_run.id)

    expect(result).to include(agent_run_id: agent_run.id, scheduled: true, code: nil)
    expect(AgentRunPhase.find_by(agent_run: agent_run)).to have_attributes(
      phase_key: "advance_partial_closeout", phase_group: "post", status: "completed"
    )
  end
end
