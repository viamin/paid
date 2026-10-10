# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Issues::UpsertFromGithub do
  describe ".call" do
    let(:project) { create(:project) }
    let(:github_issue) do
      OpenStruct.new(
        id: 1234,
        number: 42,
        title: "Sync me",
        body: "GitHub body",
        html_url: "https://github.com/test/repo/pull/42",
        state: "open",
        labels: [ OpenStruct.new(name: "paid-generated"), "P1" ],
        pull_request: OpenStruct.new(html_url: "https://github.com/test/repo/pull/42"),
        state_reason: nil,
        user: OpenStruct.new(login: "viamin"),
        created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
        updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
      )
    end

    it "creates a local issue row using the GitHub issue-shaped payload" do
      issue = described_class.call(project: project, github_issue: github_issue)

      expect(issue).to have_attributes(
        project_id: project.id,
        github_issue_id: 1234,
        github_number: 42,
        title: "Sync me",
        body: "GitHub body",
        github_state: "open",
        github_creator_login: "viamin",
        is_pull_request: true,
        github_html_url: "https://github.com/test/repo/pull/42",
        labels: [ "paid-generated", "P1" ]
      )
    end

    it "allows callers to override the stored body" do
      issue = described_class.call(project: project, github_issue: github_issue, body: nil)

      expect(issue.body).to be_nil
    end

    it "updates an existing row instead of creating a duplicate" do
      existing = create(:issue, :pull_request, project: project, github_issue_id: 1234,
        github_number: 40, title: "Old", labels: [])

      issue = described_class.call(project: project, github_issue: github_issue)

      expect(issue.id).to eq(existing.id)
      expect(project.issues.where(github_issue_id: 1234).count).to eq(1)
      expect(issue.github_number).to eq(42)
    end

    it "treats issue payloads without a pull_request attribute as plain issues" do
      github_issue_without_pull_request = OpenStruct.new(
        id: 5678,
        number: 99,
        title: "Plain issue",
        body: "No pull request payload",
        state: "open",
        labels: [],
        user: OpenStruct.new(login: "viamin"),
        created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
        updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
      )

      issue = described_class.call(project: project, github_issue: github_issue_without_pull_request)

      expect(issue.is_pull_request).to be(false)
    end

    it "delivers completion notifications when an open issue closes" do
      user = create(:user, account: project.account)
      issue = create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
      create(:issue_merge_subscription, issue: issue, user: user)

      github_issue.state = "closed"
      github_issue.pull_request = nil
      github_issue.state_reason = "completed"

      expect {
        described_class.call(project: project, github_issue: github_issue)
      }.to change(Notification, :count).by(1)

      expect(Notification.last.title).to eq("Issue #42 was completed: Sync me")
    end

    it "delivers merge notifications for pull requests closed as completed from issue sync" do
      user = create(:user, account: project.account)
      issue = create(:issue, :pull_request, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
      create(:issue_merge_subscription, issue: issue, user: user)

      github_issue.state = "closed"
      github_issue.state_reason = "completed"

      expect {
        described_class.call(project: project, github_issue: github_issue)
      }.to change(Notification, :count).by(1)

      expect(Notification.last.title).to eq("PR #42 was merged: Sync me")
    end

    it "does not deliver completion notifications for issues closed as not planned" do
      user = create(:user, account: project.account)
      issue = create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
      create(:issue_merge_subscription, issue: issue, user: user)

      github_issue.state = "closed"
      github_issue.pull_request = nil
      github_issue.state_reason = "not_planned"

      expect {
        described_class.call(project: project, github_issue: github_issue)
      }.not_to change(Notification, :count)
    end

    # @spec ISSUE-REOPEN-REVIEW-001 @spec ISSUE-REOPEN-REVIEW-002
    it "parks a reopened issue for operator review before it can be completed again" do
      create(:issue, project: project, github_issue_id: 1234, github_number: 42,
        github_state: "closed", paid_state: "recommend_close")
      github_issue.pull_request = nil

      issue = described_class.call(project: project, github_issue: github_issue)

      expect(issue).to have_attributes(
        github_state: "open",
        paid_state: "manual_review",
        manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON
      )
      expect(issue).to be_reopen_review_pending
    end

    describe "recommend_close label removal reset" do
      let(:recommend_close_label_url) do
        "https://api.github.com/repos/#{project.full_name}/issues/77/labels/paid-recommend-close"
      end

      let(:project) { create(:project, auto_pick_enabled: true) }
      let(:github_issue) do
        OpenStruct.new(
          id: 9000,
          number: 7,
          title: "Re-evaluate me",
          body: "body",
          state: "open",
          labels: [ OpenStruct.new(name: "P1") ],
          pull_request: nil,
          state_reason: nil,
          user: OpenStruct.new(login: "viamin"),
          created_at: Time.zone.parse("2026-05-18 00:00:00 UTC"),
          updated_at: Time.zone.parse("2026-05-20 00:00:00 UTC")
        )
      end

      before do
        allow(Rails.logger).to receive(:info)
      end

      def mark_github_issue_closed(number:, issue_id:)
        github_issue.id = issue_id
        github_issue.number = number
        github_issue.state = "closed"
        github_issue.state_reason = "completed"
        github_issue.pull_request = nil
      end

      def expect_recommend_close_reset_log(blocker:, dependent:)
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "recommend_close.dependency_closed_reset",
          blocker_issue_id: blocker.id,
          blocker_github_number: blocker.github_number,
          dependent_issue_id: dependent.id,
          dependent_github_number: dependent.github_number,
          project_id: project.id,
          removed_label: "paid-recommend-close"
        ))
      end

      it "resets paid_state to new and re-enqueues when the recommend_close label is removed" do
        create(:issue, project: project, github_issue_id: 9000, github_number: 7,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(project.issues.find_by(github_issue_id: 9000).paid_state).to eq("new")
      end

      # @spec AUTO-PICK-QUEUE-003
      it "resets recommend_close dependents when a dependency closes and removes the label" do
        blocker = create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
        dependent = create(:issue, project: project, github_number: 77,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

        mark_github_issue_closed(number: 42, issue_id: 1234)
        stub_request(:delete, recommend_close_label_url).to_return(status: 200, body: "", headers: {})

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(dependent.reload.paid_state).to eq("new")
        expect(dependent.labels).to eq([ "P1" ])
        expect(WebMock).to have_requested(:delete, recommend_close_label_url)
        expect_recommend_close_reset_log(blocker:, dependent:)
      end

      it "resets upstream recommend_close dependents without removing their remote label" do # @spec AUTO-PICK-QUEUE-003 UPSTREAM-ISSUE-004
        project.update!(
          pr_target: "upstream", upstream_full_name: "upstream/repo",
          auto_add_labels_enabled: false, inherit_priority_labels: false, auto_fix_merge_conflicts: false
        )
        blocker = create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
        dependent = create(:issue, project: project, github_number: 77,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
        mark_github_issue_closed(number: 42, issue_id: 1234)

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(dependent.reload).to have_attributes(paid_state: "new", labels: [ "P1" ])
        expect(WebMock).not_to have_requested(:delete, recommend_close_label_url)
      end

      # @spec AUTO-PICK-QUEUE-003
      it "keeps a recommend_close dependent parked when another dependency remains open" do
        blocker = create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
        other_blocker = create(:issue, project: project, github_number: 43, github_state: "open")
        dependent = create(:issue, project: project, github_number: 77,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
        create(:issue_dependency, issue: dependent, depends_on_issue: other_blocker)

        mark_github_issue_closed(number: 42, issue_id: 1234)

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(dependent.reload.paid_state).to eq("recommend_close")
        expect(dependent.labels).to eq([ "P1", "paid-recommend-close" ])
        expect(WebMock).not_to have_requested(:delete, recommend_close_label_url)
      end

      # @spec AUTO-PICK-QUEUE-003
      it "does not touch unrelated recommend_close issues with no dependencies" do
        create(:issue, project: project, github_issue_id: 1234, github_number: 42, github_state: "open")
        unrelated = create(:issue, project: project, github_number: 77,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])

        mark_github_issue_closed(number: 42, issue_id: 1234)

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(unrelated.reload.paid_state).to eq("recommend_close")
        expect(unrelated.labels).to eq([ "P1", "paid-recommend-close" ])
      end

      it "does not reset when the label is still present" do
        create(:issue, project: project, github_issue_id: 9000, github_number: 7,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])
        github_issue.labels = [ OpenStruct.new(name: "P1"), OpenStruct.new(name: "paid-recommend-close") ]

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(project.issues.find_by(github_issue_id: 9000).paid_state).to eq("recommend_close")
      end

      it "does not reset when paid_state is not recommend_close" do
        create(:issue, project: project, github_issue_id: 9000, github_number: 7,
          paid_state: "new", labels: [ "P1", "paid-recommend-close" ])

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)
      end

      it "uses the project-configured recommend_close label override" do
        project.update!(label_mappings: { "recommend_close" => "needs-review" })
        create(:issue, project: project, github_issue_id: 9000, github_number: 7,
          paid_state: "recommend_close", labels: [ "P1", "needs-review" ])

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(project.issues.find_by(github_issue_id: 9000).paid_state).to eq("new")
      end

      it "clears state but does not enqueue when auto_pick is disabled" do
        project.update!(auto_pick_enabled: false)
        create(:issue, project: project, github_issue_id: 9000, github_number: 7,
          paid_state: "recommend_close", labels: [ "P1", "paid-recommend-close" ])

        expect {
          described_class.call(project: project, github_issue: github_issue)
        }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)

        expect(project.issues.find_by(github_issue_id: 9000).paid_state).to eq("new")
      end
    end

    # @spec PRIORITY-LABEL-SYNC-001
    describe "priority label reconciliation on the linked pull request" do
      let(:project) { create(:project, owner: "viamin", repo: "paid") }
      let(:github_client) { instance_double(GithubClient) }
      let(:github_issue) do
        OpenStruct.new(
          id: 1234,
          number: 42,
          title: "Re-triaged issue",
          body: "body",
          state: "open",
          labels: [ "P1", "bug" ],
          pull_request: nil,
          state_reason: nil,
          user: OpenStruct.new(login: "viamin"),
          created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
          updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
        )
      end

      before do
        allow(GithubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:add_labels_to_issue)
        allow(github_client).to receive(:remove_labels_from_issue).and_return(removed: [ "P2" ], failed: [])
      end

      def link_pull_request(issue, github_number: 416)
        create(:agent_run, :completed,
          project: project,
          issue: issue,
          goal: "create_pr",
          pull_request_number: github_number,
          pull_request_url: "https://github.com/viamin/paid/pull/#{github_number}")
        create(:issue, :pull_request,
          project: project,
          github_number: github_number,
          labels: [ "P2", "paid-generated" ])
      end

      it "syncs the linked pull request when the issue's priority label changes" do
        issue = create(:issue, project: project, github_issue_id: 1234, github_number: 42, labels: [ "P2", "bug" ])
        pull_request = link_pull_request(issue)

        described_class.call(project: project, github_issue: github_issue)

        expect(github_client).to have_received(:add_labels_to_issue).with("viamin/paid", 416, [ "P1" ])
        expect(pull_request.reload.labels).to contain_exactly("paid-generated", "P1")
      end

      it "does not touch the linked pull request when the priority label is unchanged" do
        issue = create(:issue, project: project, github_issue_id: 1234, github_number: 42, labels: [ "P1", "other" ])
        link_pull_request(issue)
        github_issue.labels = [ "P1" ]

        described_class.call(project: project, github_issue: github_issue)

        expect(github_client).not_to have_received(:add_labels_to_issue)
        expect(github_client).not_to have_received(:remove_labels_from_issue)
      end

      it "does not reconcile priority labels for a synced pull request issue" do
        pr_github_issue = OpenStruct.new(
          id: 777,
          number: 416,
          title: "A PR",
          body: "body",
          state: "open",
          labels: [ "P1" ],
          pull_request: OpenStruct.new(html_url: "https://github.com/viamin/paid/pull/416"),
          state_reason: nil,
          user: OpenStruct.new(login: "viamin"),
          created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
          updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
        )
        create(:issue, :pull_request, project: project, github_issue_id: 777, github_number: 416, labels: [ "P2" ])

        described_class.call(project: project, github_issue: pr_github_issue)

        expect(github_client).not_to have_received(:add_labels_to_issue)
        expect(github_client).not_to have_received(:remove_labels_from_issue)
      end
    end
  end
end
