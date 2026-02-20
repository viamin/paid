# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteExistingPrRunActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) do
    create(:agent_run, :running, project: project, issue: issue,
      source_pull_request_number: 42,
      custom_prompt: "Fix review comments",
      result_commit_sha: "abc123def456789012345678901234567890abcd")
  end
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_head) { double("pr_head", ref: "fix-branch") } # rubocop:disable RSpec/VerifiedDoubles
  let(:pr_data) { double("pr_data", number: 42, html_url: "https://github.com/#{project.full_name}/pull/42", head: pr_head) } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)
    allow(github_client).to receive(:add_comment)
  end

  describe "#execute" do
    it "marks the agent run as completed with existing PR details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.pull_request_url).to eq("https://github.com/#{project.full_name}/pull/42")
      expect(agent_run.pull_request_number).to eq(42)
    end

    it "adds a comment to the existing PR" do
      expect(github_client).to receive(:add_comment)
        .with(project.full_name, 42, "Agent pushed updates to this PR.")

      activity.execute(agent_run_id: agent_run.id)
    end

    it "logs a system message" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("Pushed updates to existing PR")
    end

    it "updates issue paid_state to completed" do
      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "returns agent_run_id and PR details" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:pull_request_url]).to eq("https://github.com/#{project.full_name}/pull/42")
      expect(result[:pull_request_number]).to eq(42)
    end

    it "handles comment failure gracefully" do
      allow(github_client).to receive(:add_comment)
        .and_raise(GithubClient::ApiError.new("forbidden", status: 403))

      expect { activity.execute(agent_run_id: agent_run.id) }.not_to raise_error
      expect(agent_run.reload.status).to eq("completed")
    end

    context "without an issue" do
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: nil,
          source_pull_request_number: 42,
          custom_prompt: "Fix review comments",
          result_commit_sha: "abc123def456789012345678901234567890abcd")
      end

      it "completes without updating issue state" do
        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
      end
    end
  end
end
