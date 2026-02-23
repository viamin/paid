# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::QueueAgentRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  describe "#execute" do
    it "creates an agent run with queued status" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      expect(result[:queued]).to be true

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.status).to eq("queued")
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
    end

    it "stores custom_prompt and source_pull_request_number" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        custom_prompt: "Fix the bug",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.custom_prompt).to eq("Fix the bug")
      expect(agent_run.source_pull_request_number).to eq(42)
    end

    it "works without an issue" do
      result = activity.execute(
        project_id: project.id,
        custom_prompt: "Do something"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.issue).to be_nil
      expect(agent_run.custom_prompt).to eq("Do something")
    end
  end
end
