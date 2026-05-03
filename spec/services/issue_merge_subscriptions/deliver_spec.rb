# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueMergeSubscriptions::Deliver do
  describe ".call" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix login timeout") }
    let(:user) { create(:user, account: project.account) }
    let(:expected_action_url) do
      issue.github_url
    end
    let(:expected_metadata) do
      {
        "event" => "completed",
        "github_number" => 42,
        "issue_id" => issue.id,
        "project_id" => project.id
      }
    end

    it "creates a user-scoped notification and deletes the subscription" do
      create(:issue_merge_subscription, issue: issue, user: user)

      expect {
        described_class.call(issue: issue, event: :completed)
      }.to change(Notification, :count).by(1)
        .and change(IssueMergeSubscription, :count).by(-1)

      notification = Notification.last
      expect(notification).to have_attributes(
        account: project.account,
        user: user,
        source: "issue_merge_subscription",
        subject: issue,
        title: "Issue #42 was completed: Fix login timeout",
        action_url: expected_action_url,
        nav_section: "projects"
      )
      expect(notification.metadata).to include(expected_metadata)
    end

    it "is idempotent after subscriptions are consumed" do
      create(:issue_merge_subscription, issue: issue, user: user)

      described_class.call(issue: issue, event: :completed)

      expect {
        described_class.call(issue: issue, event: :completed)
      }.not_to change(Notification, :count)
    end

    it "formats pull request merge notifications correctly" do
      pull_request = create(:issue, :pull_request, project: project, github_number: 77, title: "Improve CI")
      create(:issue_merge_subscription, issue: pull_request, user: user)

      described_class.call(issue: pull_request, event: :merged)

      expect(Notification.last.title).to eq("PR #77 was merged: Improve CI")
      expect(Notification.last.action_url).to eq(pull_request.github_url)
    end
  end
end
