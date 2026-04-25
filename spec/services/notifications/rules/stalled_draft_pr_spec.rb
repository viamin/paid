# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::StalledDraftPr do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42,
      pr_review_phase: "draft", auto_continue_paused: false)
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  it "publishes after three consecutive failed draft follow-ups" do
    3.times do |index|
      create(:agent_run, :timeout, project: project, issue: issue,
        goal: "create_pr", trigger_type: "automatic",
        source_pull_request_number: 42, count_toward_draft_review_round: true,
        expected_draft_review_count: 0, created_at: (3 - index).hours.ago)
    end

    expect {
      described_class.call(scope: [ issue ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "stalled_draft_pr", subject: issue)
    expect(notification.severity).to eq("warning")
    expect(notification.metadata["consecutive_failures"]).to eq(3)
  end

  it "does not publish below the failure threshold" do
    2.times do
      create(:agent_run, :timeout, project: project, issue: issue,
        goal: "create_pr", trigger_type: "automatic",
        source_pull_request_number: 42, count_toward_draft_review_round: true,
        expected_draft_review_count: 0)
    end

    expect {
      described_class.call(scope: [ issue ])
    }.not_to change(Notification, :count)
  end

  it "resolves when the PR leaves draft" do
    create(:notification, account: account, source: "stalled_draft_pr", subject: issue)
    issue.update!(pr_review_phase: "ready")

    described_class.call(scope: [ issue ])

    expect(Notification.find_by!(source: "stalled_draft_pr", subject: issue).resolved_at).to be_present
  end

  it "re-publishes instead of creating duplicates" do
    3.times do
      create(:agent_run, :timeout, project: project, issue: issue,
        goal: "create_pr", trigger_type: "automatic",
        source_pull_request_number: 42, count_toward_draft_review_round: true,
        expected_draft_review_count: 0)
    end

    2.times { described_class.call(scope: [ issue ]) }

    expect(Notification.where(source: "stalled_draft_pr", subject: issue).count).to eq(1)
  end
end
