# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::UpdateIssueWithPrActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
  let(:issue) { create(:issue, :in_progress, project: project, labels: [ "paid-build", "bug" ]) }
  let(:agent_run) { create(:agent_run, :with_issue, project: project, issue: issue) }
  let(:pr_url) { "https://github.com/owner/repo/pull/42" }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:add_comment)
    allow(github_client).to receive(:remove_label_from_issue)
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

    it "removes the triggering label from the issue" do
      expect(github_client).to receive(:remove_label_from_issue).with(
        project.full_name,
        issue.github_number,
        "paid-build"
      )

      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
    end

    it "does not remove labels that the issue does not have" do
      expect(github_client).not_to receive(:remove_label_from_issue).with(
        anything, anything, "paid-plan"
      )

      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
    end

    it "logs the issue update to agent run" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("Issue ##{issue.github_number}")
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

      result = activity.execute(agent_run_id: agent_run_no_issue.id, pull_request_url: pr_url)

      expect(result[:agent_run_id]).to eq(agent_run_no_issue.id)
    end

    it "does not fail when GitHub comment fails" do
      allow(github_client).to receive(:add_comment)
        .and_raise(GithubClient::ApiError.new("Comment failed"))

      expect {
        activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
      }.not_to raise_error
    end

    it "does not fail when label removal fails" do
      allow(github_client).to receive(:remove_label_from_issue)
        .and_raise(GithubClient::NotFoundError)

      expect {
        activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
      }.not_to raise_error
    end

    it "skips label removal when project has no label mappings" do
      project.update!(label_mappings: {})

      expect(github_client).not_to receive(:remove_label_from_issue)

      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, pull_request_url: pr_url)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
