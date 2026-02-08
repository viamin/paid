# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateAgentRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  describe "#execute" do
    it "creates an agent run for the project and issue" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.status).to eq("pending")
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
    end

    it "updates the issue paid_state to in_progress" do
      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "raises ActiveRecord::RecordNotFound for invalid project_id" do
      expect {
        activity.execute(project_id: -1, issue_id: issue.id)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound for invalid issue_id" do
      expect {
        activity.execute(project_id: project.id, issue_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
