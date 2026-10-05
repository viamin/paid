# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::PostPartialCloseoutEvidenceActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project, labels: [ "paid-build" ]) }
  let(:agent_run) { create(:agent_run, :completed, project: project, issue: issue, pull_request_number: 99) }
  let(:pr_url) { "https://github.com/owner/repo/pull/99" }
  let(:github_client) { instance_double(GithubClient) }
  let(:marker) { described_class.evidence_marker(agent_run.id) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      authenticated_login: "paid-agents[bot]",
      recent_issue_comments: [],
      add_comment: nil
    )
  end

  def comment_with(body:, login: "paid-agents[bot]")
    OpenStruct.new(body: body, user: OpenStruct.new(login: login))
  end

  describe "#execute" do
    # @spec NO-OUTPUT-ISSUE-007
    it "posts the PR-link evidence comment on the parent issue" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(github_client).to have_received(:add_comment).with(
        project.full_name, issue.github_number,
        a_string_including("**Partial pull request created: #{pr_url}**")
      )
    end

    it "tags the evidence comment with the per-run marker" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(github_client).to have_received(:add_comment)
        .with(anything, anything, a_string_including(marker))
    end

    # @spec NO-OUTPUT-ISSUE-007
    it "keeps the parent issue incomplete without touching its labels" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.labels).to include("paid-build")
      expect(github_client).not_to have_received(:remove_label_from_issue)
    end

    it "does not duplicate the evidence when a retry already posted the marker" do
      allow(github_client).to receive(:recent_issue_comments)
        .and_return([ comment_with(body: "#{marker}\n**Partial pull request created: #{pr_url}**") ])

      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result).to include(agent_run_id: agent_run.id, posted: false)
      expect(github_client).not_to have_received(:add_comment)
    end

    it "still posts when only a non-Paid author forged the marker" do
      allow(github_client).to receive(:recent_issue_comments)
        .and_return([ comment_with(body: marker, login: "attacker") ])

      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(github_client).to have_received(:add_comment)
    end

    it "deduplicates on marker alone when no Paid author identity is resolvable" do
      allow(github_client).to receive_messages(
        authenticated_login: nil,
        recent_issue_comments: [ comment_with(body: marker, login: "anyone") ]
      )

      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result).to include(posted: false)
      expect(github_client).not_to have_received(:add_comment)
    end

    it "skips GitHub writes for upstream-readonly projects" do # @spec UPSTREAM-ISSUE-004
      project.update!(
        pr_target: "upstream", upstream_full_name: "upstream/repo",
        auto_add_labels_enabled: false, inherit_priority_labels: false, auto_fix_merge_conflicts: false
      )

      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      expect(result).to include(posted: false)
      expect(github_client).not_to have_received(:add_comment)
    end

    it "returns posted false for issue-less runs" do
      issueless_run = create(:agent_run, :completed, :with_custom_prompt, project: project)

      result = activity.execute(agent_run_id: issueless_run.id, pull_request_url: pr_url)

      expect(result).to include(agent_run_id: issueless_run.id, posted: false)
    end

    it "returns posted false when the pull request URL is blank" do
      result = activity.execute(agent_run_id: agent_run.id, pull_request_url: "")

      expect(result).to include(posted: false)
      expect(github_client).not_to have_received(:add_comment)
    end

    it "does not fail when GitHub rejects the comment" do
      allow(github_client).to receive(:add_comment)
        .and_raise(GithubClient::ApiError.new("Comment failed"))

      expect {
        activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
      }.not_to raise_error
    end

    it "does not fail when the dedup check cannot read comments" do
      allow(github_client).to receive(:recent_issue_comments)
        .and_raise(GithubClient::ApiError.new("List comments failed"))

      expect {
        activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)
      }.not_to raise_error
      expect(github_client).to have_received(:add_comment)
    end

    it "logs the evidence post to the agent run" do
      activity.execute(agent_run_id: agent_run.id, pull_request_url: pr_url)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("issue ##{issue.github_number}")
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, pull_request_url: pr_url)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
