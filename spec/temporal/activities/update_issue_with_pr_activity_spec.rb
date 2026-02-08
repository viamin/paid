# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::UpdateIssueWithPrActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: issue) }
  let(:activity) { described_class.new }
  let(:pr_url) { "https://github.com/owner/repo/pull/99" }

  describe "#execute" do
    it "marks the issue as completed" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "returns the agent_run_id" do
      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    context "when agent run has no issue" do
      let(:agent_run) { create(:agent_run, project: project, issue: nil) }

      it "completes without error" do
        result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

        expect(result[:agent_run_id]).to eq(agent_run.id)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, pull_request_url: pr_url)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
