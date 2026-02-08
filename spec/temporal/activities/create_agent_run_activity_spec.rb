# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateAgentRunActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:activity) { described_class.new }

  describe "#execute" do
    it "creates an agent run for the project and issue" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        agent_type: "claude_code"
      )

      expect(result[:agent_run_id]).to be_present
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.agent_type).to eq("claude_code")
      expect(agent_run.status).to eq("pending")
    end

    it "sets the issue paid_state to in_progress" do
      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        agent_type: "claude_code"
      )

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "stores temporal workflow and run IDs when provided" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        agent_type: "claude_code",
        temporal_workflow_id: "wf-123",
        temporal_run_id: "run-456"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.temporal_workflow_id).to eq("wf-123")
      expect(agent_run.temporal_run_id).to eq("run-456")
    end

    it "creates a workflow state when temporal_workflow_id is provided" do
      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        agent_type: "claude_code",
        temporal_workflow_id: "wf-123"
      )

      state = WorkflowState.find_by(temporal_workflow_id: "wf-123")
      expect(state).to be_present
      expect(state.workflow_type).to eq("AgentExecution")
      expect(state.status).to eq("running")
    end

    it "raises ActiveRecord::RecordNotFound for invalid project_id" do
      expect {
        activity.execute(project_id: -1, issue_id: issue.id, agent_type: "claude_code")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound for invalid issue_id" do
      expect {
        activity.execute(project_id: project.id, issue_id: -1, agent_type: "claude_code")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
