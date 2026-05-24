# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::StalledDraftPr do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, max_draft_review_rounds: 3) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42,
      pr_review_phase: "draft", auto_continue_paused: false,
      github_updated_at: 10.minutes.ago, last_pr_scan_at: 5.minutes.ago)
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(issue).to receive(:pr_progress_state).and_return(
      PullRequests::ProgressState::Result.new(
        consecutive_unsuccessful_automatic_runs: 3,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: 4.hours.ago,
        latest_unsuccessful_run_goal: "review",
        latest_unsuccessful_run_status: "failed"
      )
    )
  end

  it "publishes after the unified PR streak goes stale in draft" do
    expect {
      described_class.call(scope: [ issue ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "stalled_draft_pr", subject: issue)
    expect(notification.severity).to eq("warning")
    expect(notification.metadata["consecutive_failures"]).to eq(3)
    expect(notification.metadata["latest_unsuccessful_run_goal"]).to eq("review")
  end

  it "does not publish below the failure threshold" do
    allow(issue).to receive(:pr_progress_state).and_return(
      PullRequests::ProgressState::Result.new(
        consecutive_unsuccessful_automatic_runs: 2,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: 4.hours.ago,
        latest_unsuccessful_run_goal: "create_pr",
        latest_unsuccessful_run_status: "failed"
      )
    )

    expect {
      described_class.call(scope: [ issue ])
    }.not_to change(Notification, :count)
  end

  it "does not publish until the latest GitHub update has been scanned" do
    issue.update!(github_updated_at: 1.minute.ago, last_pr_scan_at: 5.minutes.ago)

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
    2.times { described_class.call(scope: [ issue ]) }

    expect(Notification.where(source: "stalled_draft_pr", subject: issue).count).to eq(1)
  end
end
