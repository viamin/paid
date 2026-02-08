# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreatePullRequestActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, title: "Fix the login bug", github_number: 42) }
  let(:agent_run) do
    create(:agent_run, :with_git_context, project: project, issue: issue,
           result_commit_sha: "abc123def456789012345678901234567890abcd")
  end
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }
  let(:github_token) { agent_run.project.github_token }
  let(:pr_response) do
    OpenStruct.new(html_url: "https://github.com/owner/repo/pull/99", number: 99)
  end

  describe "#execute" do
    before do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(github_token).to receive(:client).and_return(github_client)
    end

    it "creates a pull request via GitHub API" do
      expect(github_client).to receive(:create_pull_request)
        .with(
          project.full_name,
          base: project.default_branch,
          head: agent_run.branch_name,
          title: "Fix #42: Fix the login bug",
          body: anything
        )
        .and_return(pr_response)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:pull_request_url]).to eq("https://github.com/owner/repo/pull/99")
      expect(result[:pull_request_number]).to eq(99)
    end

    it "updates the agent run with PR details" do
      allow(github_client).to receive(:create_pull_request).and_return(pr_response)

      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.pull_request_url).to eq("https://github.com/owner/repo/pull/99")
      expect(agent_run.pull_request_number).to eq(99)
      expect(agent_run.status).to eq("completed")
    end
  end

  it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
    expect {
      activity.execute(agent_run_id: -1)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
