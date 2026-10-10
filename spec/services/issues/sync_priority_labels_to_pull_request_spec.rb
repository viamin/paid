# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::SyncPriorityLabelsToPullRequest do
  describe ".call" do
    let(:project) { create(:project, owner: "viamin", repo: "paid") }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:add_labels_to_issue)
      allow(github_client).to receive(:remove_labels_from_issue).and_return(removed: [], failed: [])
    end

    def create_linked_pull_request(issue, pr_labels:, github_number: 416)
      create(:agent_run, :completed,
        project: project,
        issue: issue,
        goal: "create_pr",
        pull_request_number: github_number,
        pull_request_url: "https://github.com/viamin/paid/pull/#{github_number}")
      create(:issue, :pull_request,
        project: project,
        github_number: github_number,
        labels: pr_labels)
    end

    # @spec PRIORITY-LABEL-SYNC-001
    it "adds a newly set priority label and removes the stale one" do
      issue = create(:issue, project: project, labels: [ "P1", "bug" ])
      pull_request = create_linked_pull_request(issue, pr_labels: [ "P2", "paid-generated" ])
      allow(github_client).to receive(:remove_labels_from_issue).and_return(removed: [ "P2" ], failed: [])

      described_class.call(issue: issue, project: project)

      expect(github_client).to have_received(:add_labels_to_issue).with("viamin/paid", 416, [ "P1" ])
      expect(github_client).to have_received(:remove_labels_from_issue).with("viamin/paid", 416, [ "P2" ])
      expect(pull_request.reload.labels).to contain_exactly("paid-generated", "P1")
    end

    # @spec PRIORITY-LABEL-SYNC-001
    it "removes the priority label entirely when the issue's priority is cleared" do
      issue = create(:issue, project: project, labels: [ "bug" ])
      pull_request = create_linked_pull_request(issue, pr_labels: [ "P2", "paid-generated" ])
      allow(github_client).to receive(:remove_labels_from_issue).and_return(removed: [ "P2" ], failed: [])

      described_class.call(issue: issue, project: project)

      expect(github_client).not_to have_received(:add_labels_to_issue)
      expect(github_client).to have_received(:remove_labels_from_issue).with("viamin/paid", 416, [ "P2" ])
      expect(pull_request.reload.labels).to contain_exactly("paid-generated")
    end

    # @spec PRIORITY-LABEL-SYNC-003
    it "never touches non-priority labels" do
      issue = create(:issue, project: project, labels: [ "P1", "bug", "needs-design" ])
      pull_request = create_linked_pull_request(issue, pr_labels: [ "paid-generated", "paid-automation" ])

      described_class.call(issue: issue, project: project)

      expect(github_client).to have_received(:add_labels_to_issue).with("viamin/paid", 416, [ "P1" ])
      expect(github_client).not_to have_received(:remove_labels_from_issue)
      expect(pull_request.reload.labels).to contain_exactly("paid-generated", "paid-automation", "P1")
    end

    it "is a no-op when the priority labels already match" do
      issue = create(:issue, project: project, labels: [ "P1" ])
      create_linked_pull_request(issue, pr_labels: [ "P1", "paid-generated" ])

      described_class.call(issue: issue, project: project)

      expect(github_client).not_to have_received(:add_labels_to_issue)
      expect(github_client).not_to have_received(:remove_labels_from_issue)
    end

    # @spec PRIORITY-LABEL-SYNC-002
    it "does not sync when inherit_priority_labels is disabled" do
      project.update!(inherit_priority_labels: false)
      issue = create(:issue, project: project, labels: [ "P1" ])
      create_linked_pull_request(issue, pr_labels: [ "P2" ])

      described_class.call(issue: issue, project: project)

      expect(github_client).not_to have_received(:add_labels_to_issue)
      expect(github_client).not_to have_received(:remove_labels_from_issue)
    end

    # @spec PRIORITY-LABEL-SYNC-002
    it "does not sync when the project targets PRs upstream" do
      project.update!(
        pr_target: "upstream", upstream_full_name: "upstream/repo",
        auto_add_labels_enabled: false, inherit_priority_labels: false, auto_fix_merge_conflicts: false
      )
      issue = create(:issue, project: project, labels: [ "P1" ])
      create(:agent_run, :completed,
        project: project,
        issue: issue,
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/upstream/repo/pull/416")
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        github_html_url: "https://github.com/upstream/repo/pull/416",
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        labels: [ "P2" ])

      described_class.call(issue: issue, project: project)

      expect(github_client).not_to have_received(:add_labels_to_issue)
      expect(github_client).not_to have_received(:remove_labels_from_issue)
    end

    # @spec PRIORITY-LABEL-SYNC-002
    it "is a no-op when the issue has no open Paid-created pull request" do
      issue = create(:issue, project: project, labels: [ "P1" ])

      expect { described_class.call(issue: issue, project: project) }.not_to raise_error
      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    it "does not sync against a pull request the issue itself is" do
      pull_request = create(:issue, :pull_request, project: project, labels: [ "P1" ])

      described_class.call(issue: pull_request, project: project)

      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    # @spec PRIORITY-LABEL-SYNC-004
    it "logs and swallows a GithubClient error instead of raising" do
      issue = create(:issue, project: project, labels: [ "P1" ])
      pull_request = create_linked_pull_request(issue, pr_labels: [ "P2" ])
      allow(github_client).to receive(:add_labels_to_issue).and_raise(GithubClient::ApiError.new("boom", status: 500))
      allow(Rails.logger).to receive(:warn)

      expect { described_class.call(issue: issue, project: project) }.not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "github_sync.priority_labels_reconcile_failed",
        project_id: project.id,
        pull_request_id: pull_request.id
      ))
      expect(pull_request.reload.labels).to eq([ "P2" ])
    end

    # @spec PRIORITY-LABEL-SYNC-005
    it "enqueues a bounded retry job when the GitHub write fails" do
      issue = create(:issue, project: project, labels: [ "P1" ])
      create_linked_pull_request(issue, pr_labels: [ "P2" ])
      allow(github_client).to receive(:add_labels_to_issue).and_raise(GithubClient::ApiError.new("boom", status: 500))

      expect { described_class.call(issue: issue, project: project) }
        .to have_enqueued_job(Issues::SyncPriorityLabelsToPullRequestJob).with(issue.id)
    end

    # @spec PRIORITY-LABEL-SYNC-005
    it "does not enqueue a retry when reconciliation succeeds" do
      issue = create(:issue, project: project, labels: [ "P1" ])
      create_linked_pull_request(issue, pr_labels: [ "P2" ])

      expect { described_class.call(issue: issue, project: project) }
        .not_to have_enqueued_job(Issues::SyncPriorityLabelsToPullRequestJob)
    end

    # @spec PRIORITY-LABEL-SYNC-005
    it "re-raises the GithubClient error from call! without enqueueing a retry" do
      issue = create(:issue, project: project, labels: [ "P1" ])
      create_linked_pull_request(issue, pr_labels: [ "P2" ])
      allow(github_client).to receive(:add_labels_to_issue).and_raise(GithubClient::ApiError.new("boom", status: 500))

      expect { described_class.call!(issue: issue) }.to raise_error(GithubClient::ApiError)
      expect(Issues::SyncPriorityLabelsToPullRequestJob).not_to have_been_enqueued
    end
  end
end
