# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunCompleteActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }
  let(:agent_run) { create(:agent_run, :running, project: project, issue: issue) }
  let(:activity) { described_class.new }

  describe "#execute" do
    it "marks the agent run as completed" do
      activity.execute(agent_run_id: agent_run.id, reason: "no_changes")

      expect(agent_run.reload.status).to eq("completed")
    end

    it "logs the completion reason" do
      activity.execute(agent_run_id: agent_run.id, reason: "no_changes")

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("no_changes")
    end

    it "marks the associated issue as completed" do
      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    context "when agent run has no issue" do
      let(:agent_run) { create(:agent_run, :running, project: project, issue: nil) }

      it "completes without error" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:agent_run_id]).to eq(agent_run.id)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
