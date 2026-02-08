# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::UpdateIssueWithPrActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }
  let(:agent_run) { create(:agent_run, :with_issue, project: project, issue: issue) }
  let(:pr_url) { "https://github.com/owner/repo/pull/42" }

  describe "#execute" do
    it "updates the issue paid_state to completed" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "returns agent_run_id" do
      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "handles agent runs without an issue" do
      agent_run_no_issue = create(:agent_run, project: project)

      result = activity.execute(agent_run_id: agent_run_no_issue.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run_no_issue.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, pull_request_url: pr_url)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
