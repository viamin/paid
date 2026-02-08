# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreatePullRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, :with_issue, project: project, issue: issue) }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_response) { OpenStruct.new(html_url: "https://github.com/owner/repo/pull/42", number: 42) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_pull_request).and_return(pr_response)
  end

  describe "#execute" do
    it "creates a pull request via the GitHub API" do
      expect(github_client).to receive(:create_pull_request).with(
        project.full_name,
        base: project.default_branch,
        head: agent_run.branch_name,
        title: "Fix ##{issue.github_number}: #{issue.title}",
        body: a_string_including("Closes ##{issue.github_number}")
      ).and_return(pr_response)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/42")
      expect(result[:pull_request_number]).to eq(42)
    end

    it "marks the agent run as completed with PR details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.pull_request_url).to eq("https://github.com/owner/repo/pull/42")
      expect(agent_run.pull_request_number).to eq(42)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
