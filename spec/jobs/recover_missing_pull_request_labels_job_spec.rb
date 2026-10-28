# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe RecoverMissingPullRequestLabelsJob do
  def create_unlinked_pr_and_run(project)
    source = create(:issue, project: project)
    run = create(:agent_run, :failed, project: project, issue: source, goal: "create_pr", completed_at: 1.hour.ago)
    pull_request = create(
      :issue, :pull_request, project: project, parent_issue: source,
      github_number: 4716,
      github_html_url: "https://github.com/viamin/paid/pull/4716",
      github_created_at: 90.minutes.ago,
      labels: []
    )
    [ run, pull_request ]
  end

  describe "#perform" do
    let(:project) { create(:project, owner: "viamin", repo: "paid") }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:add_labels_to_issue)
      allow(github_client).to receive(:issue).and_return(
        OpenStruct.new(
          id: 9001,
          number: 416,
          title: "Recovered PR",
          body: "Recovered body",
          state: "open",
          labels: [],
          pull_request: OpenStruct.new(html_url: "https://github.com/viamin/paid/pull/416"),
          user: OpenStruct.new(login: "viamin"),
          created_at: 1.day.ago,
          updated_at: Time.current
        )
      )
    end

    it "reapplies the generated and automation labels when both are missing" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      pull_request = create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue)
        .with("viamin/paid", 416, [ "paid-generated", "paid-automation" ])
      expect(pull_request.reload.labels).to include("paid-generated", "paid-automation")
    end

    context "when the generated label is already present" do
      it "skips recovery" do
        create(:agent_run, :completed,
          project: project,
          issue: nil,
          custom_prompt: "Create PR",
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [ "paid-generated" ])

        described_class.perform_now

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    context "when priority labels need to be inherited" do
      it "recovers missing priority labels alongside generated/automation" do
        issue = create(:issue, project: project, labels: [ "P1", "bug" ])
        create(:agent_run, :completed,
          project: project,
          issue: issue,
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [])

        described_class.perform_now

        expect(github_client).to have_received(:add_labels_to_issue)
          .with("viamin/paid", 416, [ "paid-generated", "paid-automation", "P1" ])
      end

      it "recovers only the missing priority label when generated is already present" do
        issue = create(:issue, project: project, labels: [ "P1", "bug" ])
        create(:agent_run, :completed,
          project: project,
          issue: issue,
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [ "paid-generated", "paid-automation" ])

        described_class.perform_now

        expect(github_client).to have_received(:add_labels_to_issue)
          .with("viamin/paid", 416, [ "P1" ])
      end

      it "still recovers priority labels when auto_add_labels is disabled" do
        project.update!(auto_add_labels_enabled: false)
        issue = create(:issue, project: project, labels: [ "P1" ])
        create(:agent_run, :completed,
          project: project,
          issue: issue,
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [])

        described_class.perform_now

        expect(github_client).to have_received(:add_labels_to_issue)
          .with("viamin/paid", 416, [ "P1" ])
      end

      it "skips priority recovery when inherit_priority_labels is disabled" do
        project.update!(inherit_priority_labels: false)
        issue = create(:issue, project: project, labels: [ "P1" ])
        create(:agent_run, :completed,
          project: project,
          issue: issue,
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [ "paid-generated", "paid-automation" ])

        described_class.perform_now

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    context "when only the automation label is missing" do
      it "preserves manual opt-out" do
        create(:agent_run, :completed,
          project: project,
          issue: nil,
          custom_prompt: "Create PR",
          goal: "create_pr",
          pull_request_number: 416,
          pull_request_url: "https://github.com/viamin/paid/pull/416")
        create(:issue, :pull_request,
          project: project,
          github_number: 416,
          labels: [ "paid-generated" ])

        described_class.perform_now

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end
    end

    it "reapplies only the generated label when automation is still present" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      pull_request = create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [ "paid-automation" ])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue)
        .with("viamin/paid", 416, [ "paid-generated" ])
      expect(pull_request.reload.labels).to include("paid-generated", "paid-automation")
    end

    it "continues when GitHub relabeling fails" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      pull_request = create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])
      allow(github_client).to receive(:add_labels_to_issue)
        .and_raise(GithubClient::ApiError.new("boom", status: 422))

      expect { described_class.perform_now }.not_to raise_error
      expect(pull_request.reload.labels).to eq([])
    end

    it "recovers labels for a long-running agent run completed within the window" do
      # @spec PR-LABEL-RECOVERY-001
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416",
        created_at: 3.days.ago)
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue)
        .with("viamin/paid", 416, [ "paid-generated", "paid-automation" ])
    end

    it "skips runs completed more than 24 hours ago" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416",
        created_at: 3.days.ago,
        completed_at: 25.hours.ago)
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    it "does not recover labels for PRs created against an upstream repository" do # @spec UPSTREAM-PR-005
      project.update!(
        pr_target: "upstream", upstream_full_name: "upstream/repo",
        auto_add_labels_enabled: false, inherit_priority_labels: false, auto_fix_merge_conflicts: false
      )
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/upstream/repo/pull/416")
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        github_html_url: "https://github.com/upstream/repo/pull/416",
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        labels: [])

      described_class.perform_now

      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    it "backfills a missing local PR row before recovering labels" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")

      described_class.perform_now

      expect(github_client).to have_received(:issue).with("viamin/paid", 416)
      expect(project.issues.pull_requests_only.find_by!(github_number: 416).github_issue_id).to eq(9001)
      expect(github_client).to have_received(:add_labels_to_issue)
    end

    it "deduplicates multiple completed runs for the same PR" do
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR A",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      create(:agent_run, :completed,
        project: project,
        issue: nil,
        custom_prompt: "Create PR B",
        goal: "create_pr",
        pull_request_number: 416,
        pull_request_url: "https://github.com/viamin/paid/pull/416")
      create(:issue, :pull_request,
        project: project,
        github_number: 416,
        labels: [])

      described_class.perform_now

      expect(github_client).to have_received(:add_labels_to_issue).once
    end

    it "recovers unique missing linkage from trusted local source evidence without restoring labels" do # @spec PR-LABEL-RECOVERY-003
      run, pull_request = create_unlinked_pr_and_run(project)

      described_class.perform_now

      expect(run.reload).to have_attributes(
        pull_request_number: 4716,
        pull_request_url: pull_request.github_html_url
      )
      expect(github_client).not_to have_received(:add_labels_to_issue)
      expect(run.reconciliation).to include("pull_request_link_recovered" => true)
    end

    it "does not guess linkage when a source has multiple unlinked open PRs" do # @spec PR-LABEL-RECOVERY-003
      source = create(:issue, project: project)
      run = create(:agent_run, :timeout, project: project, issue: source, goal: "create_pr", completed_at: 1.hour.ago)
      create(:issue, :pull_request, project: project, parent_issue: source, github_number: 4715, labels: [])
      create(:issue, :pull_request, project: project, parent_issue: source, github_number: 4716, labels: [])

      described_class.perform_now

      expect(run.reload.pull_request_number).to be_nil
      expect(github_client).not_to have_received(:add_labels_to_issue)
    end

    it "recovers linkage idempotently" do # @spec PR-LABEL-RECOVERY-003
      source = create(:issue, project: project)
      run = create(:agent_run, :cancelled, project: project, issue: source, goal: "create_pr", completed_at: 1.hour.ago)
      create(:issue, :pull_request, project: project, parent_issue: source, github_number: 4685, labels: [])

      2.times { described_class.perform_now }

      expect(run.reload.pull_request_number).to eq(4685)
      expect(github_client).not_to have_received(:add_labels_to_issue)
    end
  end
end
