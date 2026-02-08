# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunFailedActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }
  let(:agent_run) { create(:agent_run, :running, project: project, issue: issue) }
  let(:activity) { described_class.new }

  describe "#execute" do
    it "marks the agent run as failed" do
      activity.execute(agent_run_id: agent_run.id, error: "Something went wrong")

      agent_run.reload
      expect(agent_run.status).to eq("failed")
      expect(agent_run.error_message).to eq("Something went wrong")
    end

    it "logs the error" do
      activity.execute(agent_run_id: agent_run.id, error: "Something went wrong")

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("Something went wrong")
    end

    it "marks the associated issue as failed" do
      activity.execute(agent_run_id: agent_run.id, error: "Something went wrong")

      expect(issue.reload.paid_state).to eq("failed")
    end

    it "updates workflow state when temporal_workflow_id is present" do
      agent_run.update!(temporal_workflow_id: "wf-123")

      # Create initial workflow state
      WorkflowState.create!(
        temporal_workflow_id: "wf-123",
        workflow_type: "AgentExecution",
        status: "running"
      )

      activity.execute(agent_run_id: agent_run.id, error: "Something went wrong")

      state = WorkflowState.find_by(temporal_workflow_id: "wf-123")
      expect(state.status).to eq("failed")
    end

    context "when agent run has no issue" do
      let(:agent_run) { create(:agent_run, :running, project: project, issue: nil) }

      it "fails without error" do
        result = activity.execute(agent_run_id: agent_run.id, error: "test error")

        expect(result[:agent_run_id]).to eq(agent_run.id)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, error: "test")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
