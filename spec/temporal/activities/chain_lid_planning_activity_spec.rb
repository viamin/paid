# frozen_string_literal: true

# @spec CREATE-FEATURE-004
require "rails_helper"

RSpec.describe Activities::ChainLidPlanningActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, lid_mode: "full") }
  let(:runner) { create(:runner, user: project.created_by) }
  let(:initiating_user) { create(:user, account: project.account) }
  let(:agent_run) do
    create(:agent_run, :create_feature_goal, :completed,
      project: project,
      runner: runner,
      initiating_user: initiating_user)
  end

  describe "#execute" do
    it "creates a queued lid_planning follow-up and enqueues the run queue" do
      result = nil

      expect {
        result = activity.execute(
          agent_run_id: agent_run.id,
          plan_doc_source: "https://github.com/example/repo/pull/42"
        )
      }.to have_enqueued_job(ProcessRunQueueJob)

      followup = AgentRun.find(result[:agent_run_id])

      expect(result).to eq(agent_run_id: followup.id, queued: true)
      expect(followup).to have_attributes(
        goal: "lid_planning",
        status: "queued",
        trigger_type: "automatic",
        auto_pick: true,
        plan_doc_source: "https://github.com/example/repo/pull/42",
        project: project,
        initiating_user: initiating_user,
        runner: runner,
        agent_type: agent_run.agent_type
      )
    end

    it "skips when the project is not LID-enabled" do
      non_lid_project = create(:project, lid_mode: nil)
      run = create(:agent_run, :create_feature_goal, :completed, project: non_lid_project)

      result = activity.execute(agent_run_id: run.id, plan_doc_source: "PR #1")

      expect(result).to eq(skipped: true, reason: "lid_mode_not_set")
      expect(AgentRun.where(project: non_lid_project, goal: "lid_planning")).to be_empty
    end

    it "skips when an active lid_planning run already exists for the project" do
      create(:agent_run, :lid_planning_goal, project: project, status: "queued")

      result = activity.execute(
        agent_run_id: agent_run.id,
        plan_doc_source: "https://github.com/example/repo/pull/42"
      )

      expect(result).to eq(skipped: true, reason: "active_lid_planning_exists")
      expect(AgentRun.where(project: project, goal: "lid_planning").count).to eq(1)
    end
  end
end
