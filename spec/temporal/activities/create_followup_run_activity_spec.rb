# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateFollowupRunActivity do
  describe "#execute" do
    let(:activity) { described_class.new }
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:runner) { create(:runner, user: project.created_by) }
    let(:initiating_user) { create(:user, account: project.account) }
    let(:analysis_run) do
      create(:agent_run, :analyze_issue_goal, :completed,
        project: project,
        issue: issue,
        runner: runner,
        initiating_user: initiating_user)
    end

    it "queues an auto-pick follow-up run using the analysis run context" do
      result = activity.execute(agent_run_id: analysis_run.id, goal: "create_pr")
      followup = AgentRun.find(result[:followup_agent_run_id])

      expect(result).to eq(
        agent_run_id: analysis_run.id,
        followup_agent_run_id: followup.id,
        goal: "create_pr",
        queued: true,
        duplicate: false,
        cross_goal: false
      )
      expect(followup.goal).to eq("create_pr")
      expect(followup.status).to eq("queued")
      expect(followup.auto_pick).to be(true)
      expect(followup.runner).to eq(runner)
      expect(followup.initiating_user).to eq(initiating_user)
    end

    it "reuses an existing unfinished run for the same issue even when the goal differs" do
      existing = create(:agent_run, project: project, issue: issue, goal: "enhance_issue", status: "queued")

      result = activity.execute(agent_run_id: analysis_run.id, goal: "create_pr")

      expect(result).to eq(
        agent_run_id: analysis_run.id,
        followup_agent_run_id: existing.id,
        goal: "create_pr",
        queued: false,
        duplicate: true,
        cross_goal: true
      )
      expect(
        AgentRun.where(project: project, issue: issue, status: AgentRun::UNFINISHED_STATUSES).count
      ).to eq(1)
    end
  end
end
