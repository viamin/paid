# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunFailedActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "marks the agent run as failed with error message" do
      agent_run = create(:agent_run, :running, project: project)

      activity.execute(agent_run_id: agent_run.id, error: "Container crashed")

      agent_run.reload
      expect(agent_run.status).to eq("failed")
      expect(agent_run.error_message).to eq("Container crashed")
    end

    it "logs the failure" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, error: "Container crashed")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("Container crashed")
    end

    it "updates issue paid_state to failed when issue exists" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :with_issue, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id, error: "Timeout")

      expect(issue.reload.paid_state).to eq("failed")
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, error: "error")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
