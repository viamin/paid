# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunCompleteActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    context "when goal is create_pr" do
      it "marks the agent run as no_output" do
        agent_run = create(:agent_run, :running, project: project)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("no_output")
      end

      it "stores the reason in error_message" do
        agent_run = create(:agent_run, :running, project: project)

        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")

        expect(agent_run.reload.error_message).to eq("no_changes")
      end
    end

    context "when goal is not create_pr" do
      it "marks the agent run as completed" do
        agent_run = create(:agent_run, :running, :create_issue_goal, project: project)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
      end
    end

    it "logs the completion reason" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("no_changes")
    end

    it "updates issue paid_state to completed for non-PR goals" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :create_issue_goal, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "does not update issue paid_state for no_output create_pr runs" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "enqueues ProcessRunQueueJob" do
      agent_run = create(:agent_run, :running, project: project)

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
