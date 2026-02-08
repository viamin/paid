# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunCompleteActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "marks the agent run as completed" do
      agent_run = create(:agent_run, :running, project: project)

      activity.execute(agent_run_id: agent_run.id)

      expect(agent_run.reload.status).to eq("completed")
    end

    it "logs the completion reason" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("no_changes")
    end

    it "updates issue paid_state to completed when issue exists" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :with_issue, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
