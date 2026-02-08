# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::UpdateIssueWithPrActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }
  let(:agent_run) { create(:agent_run, :with_issue, project: project, issue: issue) }
  let(:pr_url) { "https://github.com/owner/repo/pull/42" }
  let(:github_client) { instance_double(Octokit::Client) }
  let(:github_token) { instance_double(GithubToken, client: github_client) }

  before do
    allow(project).to receive(:github_token).and_return(github_token)
    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(agent_run).to receive(:project).and_return(project)
    allow(github_client).to receive(:add_comment)
  end

  describe "#execute" do
    it "updates the issue paid_state to completed" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "posts a comment on the GitHub issue with the PR link" do
      expect(github_client).to receive(:add_comment).with(
        project.full_name,
        issue.github_number,
        "Pull request created: #{pr_url}"
      )

      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
    end

    it "does not post a comment when pull_request_url is blank" do
      expect(github_client).not_to receive(:add_comment)

      activity.execute(agent_run_id: agent_run.id, pull_request_url: "")
    end

    it "returns agent_run_id" do
      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "handles agent runs without an issue" do
      agent_run_no_issue = create(:agent_run, project: project)
      allow(AgentRun).to receive(:find).with(agent_run_no_issue.id).and_return(agent_run_no_issue)

      result = activity.execute(agent_run_id: agent_run_no_issue.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run_no_issue.id)
    end

    it "does not fail when GitHub comment fails" do
      allow(github_client).to receive(:add_comment).and_raise(Octokit::Error)

      expect {
        activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
      }.not_to raise_error
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      allow(AgentRun).to receive(:find).and_call_original

      expect {
        activity.execute(agent_run_id: -1, pull_request_url: pr_url)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
