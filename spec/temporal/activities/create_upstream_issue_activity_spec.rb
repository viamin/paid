# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateUpstreamIssueActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt,
      project: project, goal: "create_issue", custom_prompt: "Create cross-repo issue pair")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:issue_response) do
    Struct.new(:html_url, :number, :id, :title, :body, :state, :user, :labels, :pull_request, :created_at, :updated_at).new(
      "https://github.com/upstream-owner/upstream-repo/issues/5",
      5,
      99999,
      "Upstream feature request",
      "Body of upstream issue",
      "open",
      Struct.new(:login).new("paid-bot"),
      [],
      nil,
      Time.current,
      Time.current
    )
  end

  before do
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)

    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(issue_response)
  end

  describe "#execute" do
    let(:input) do
      {
        agent_run_id: agent_run.id,
        target_repo: "upstream-owner/upstream-repo",
        title: "Upstream feature request",
        body: "Body of upstream issue"
      }
    end

    it "creates an issue in the target repository" do
      expect(github_client).to receive(:create_issue).with(
        "upstream-owner/upstream-repo",
        title: "Upstream feature request",
        body: "Body of upstream issue",
        labels: []
      ).and_return(issue_response)

      result = activity.execute(input)

      expect(result[:issue_url]).to eq("https://github.com/upstream-owner/upstream-repo/issues/5")
      expect(result[:issue_number]).to eq(5)
      expect(result[:target_repo]).to eq("upstream-owner/upstream-repo")
    end

    it "records the upstream issue in cross_repo_issues" do
      activity.execute(input)

      agent_run.reload
      expect(agent_run.cross_repo_issues).to contain_exactly(
        a_hash_including(
          "repo" => "upstream-owner/upstream-repo",
          "issue_number" => 5,
          "issue_url" => "https://github.com/upstream-owner/upstream-repo/issues/5",
          "role" => "upstream"
        )
      )
    end

    it "logs the upstream issue creation" do
      activity.execute(input)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("Upstream issue created")
      expect(log.content).to include("upstream-owner/upstream-repo")
    end

    it "passes labels when provided" do
      input_with_labels = input.merge(labels: %w[upstream enhancement])

      expect(github_client).to receive(:create_issue).with(
        "upstream-owner/upstream-repo",
        title: "Upstream feature request",
        body: "Body of upstream issue",
        labels: %w[upstream enhancement]
      ).and_return(issue_response)

      activity.execute(input_with_labels)
    end

    it "syncs the issue record when target project exists in same account" do
      target_project = create(:project, account: project.account, owner: "upstream-owner", repo: "upstream-repo")

      expect(Issues::UpsertFromGithub).to receive(:call).with(
        project: target_project,
        github_issue: issue_response
      )

      activity.execute(input)
    end

    it "skips sync when target project does not exist in same account" do
      expect(Issues::UpsertFromGithub).not_to receive(:call)

      activity.execute(input)
    end

    context "when no GitHub token is available" do
      before do
        allow(project).to receive(:github_token).and_return(nil)
        allow(AgentRun).to receive(:find).and_return(agent_run)
        allow(agent_run).to receive(:project).and_return(project)
      end

      it "raises a non-retryable error" do
        expect {
          activity.execute(input)
        }.to raise_error(Temporalio::Error::ApplicationError, /No GitHub token/)
      end
    end
  end
end
