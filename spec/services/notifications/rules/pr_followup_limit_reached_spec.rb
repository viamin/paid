# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::PrFollowupLimitReached do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, max_pr_followup_runs: 3) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42,
      pr_review_phase: "ready", pr_followup_count: 3,
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
        latest_unsuccessful_run_at: nil,
        latest_unsuccessful_run_goal: "create_pr",
        latest_unsuccessful_run_status: "failed"
      )
    )
  end

  describe "#detect", :no_db do
    let(:project) { double(max_pr_followup_runs: 3) }
    let(:issue) do
      double(
        id: 42,
        is_pull_request?: true,
        github_state: "open",
        pr_review_phase: "ready",
        last_pr_scan_at: last_pr_scan_at,
        github_updated_at: github_updated_at,
        project: project
      )
    end
    let(:rule) { described_class.new }
    let(:last_pr_scan_at) { Time.zone.parse("2026-05-15 12:05:00") }
    let(:github_updated_at) { Time.zone.parse("2026-05-15 12:00:00") }

    before do
      allow(issue).to receive(:pr_progress_state).and_return(
        PullRequests::ProgressState::Result.new(
          consecutive_unsuccessful_automatic_runs: 3,
          consecutive_operational_failures: 0,
          last_meaningful_progress_at: nil,
          latest_automatic_run_at: nil,
          latest_unsuccessful_run_at: nil,
          latest_unsuccessful_run_goal: "create_pr",
          latest_unsuccessful_run_status: "failed"
        )
      )
    end

    it "matches when the PR scan is newer than the latest GitHub update" do
      expect(rule.send(:detect, [ issue ])).to eq([ issue ])
    end

    it "matches when the PR scan timestamp equals the latest GitHub update" do
      allow(issue).to receive_messages(
        last_pr_scan_at: Time.zone.parse("2026-05-15 12:05:00"),
        github_updated_at: Time.zone.parse("2026-05-15 12:05:00")
      )

      expect(rule.send(:detect, [ issue ])).to eq([ issue ])
    end

    it "matches when the latest GitHub update time is unknown" do
      allow(issue).to receive(:github_updated_at).and_return(nil)

      expect(rule.send(:detect, [ issue ])).to eq([ issue ])
    end

    it "does not match until the latest GitHub update has been scanned" do
      allow(issue).to receive(:github_updated_at).and_return(Time.zone.parse("2026-05-15 12:10:00"))

      expect(rule.send(:detect, [ issue ])).to eq([])
      expect(issue).not_to have_received(:pr_progress_state)
    end

    it "prefers scan-derived progress state over stale issue memoization" do
      stale_state = instance_double(PullRequests::ProgressState::Result)
      rule = described_class.new(progress_states: [ {
        issue_id: 123,
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0
      } ])
      allow(issue).to receive_messages(pr_progress_state: stale_state, id: 123)

      expect(rule.send(:detect, [ issue ])).to eq([])
      expect(issue).not_to have_received(:pr_progress_state)
    end

    it "accepts string issue ids from serialized workflow payloads" do
      stale_state = instance_double(PullRequests::ProgressState::Result)
      rule = described_class.new(progress_states: [ {
        issue_id: "42",
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0
      } ])
      allow(issue).to receive(:pr_progress_state).and_return(stale_state)

      expect(rule.send(:detect, [ issue ])).to eq([])
      expect(issue).not_to have_received(:pr_progress_state)
    end

    it "does not match when the latest unsuccessful run was a review failure" do
      allow(issue).to receive(:pr_progress_state).and_return(
        PullRequests::ProgressState::Result.new(
          consecutive_unsuccessful_automatic_runs: 3,
          consecutive_operational_failures: 0,
          last_meaningful_progress_at: nil,
          latest_automatic_run_at: nil,
          latest_unsuccessful_run_at: nil,
          latest_unsuccessful_run_goal: "review",
          latest_unsuccessful_run_status: "failed"
        )
      )

      expect(rule.send(:detect, [ issue ])).to eq([])
    end
  end

  it "publishes when the follow-up limit is reached" do
    expect {
      described_class.call(scope: [ issue ])
    }.to change(Notification, :count).by(1)
  end

  it "does not publish below the threshold" do
    allow(issue).to receive(:pr_progress_state).and_return(
      PullRequests::ProgressState::Result.new(
        consecutive_unsuccessful_automatic_runs: 2,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: nil,
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

  it "does not resolve an existing notification until the latest GitHub update has been scanned" do
    issue.update!(github_updated_at: 1.minute.ago, last_pr_scan_at: 5.minutes.ago)
    create(:notification, account: account, source: "pr_followup_limit_reached", subject: issue)
    allow(issue).to receive(:pr_progress_state).and_return(
      PullRequests::ProgressState::Result.new(
        consecutive_unsuccessful_automatic_runs: 2,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: nil,
        latest_unsuccessful_run_goal: "create_pr",
        latest_unsuccessful_run_status: "failed"
      )
    )

    described_class.call(scope: [ issue ])

    expect(Notification.find_by!(source: "pr_followup_limit_reached", subject: issue).resolved_at).to be_nil
  end

  it "resolves when the PR closes" do
    create(:notification, account: account, source: "pr_followup_limit_reached", subject: issue)
    issue.update!(github_state: "closed")

    described_class.call(scope: [ issue ])

    expect(Notification.find_by!(source: "pr_followup_limit_reached", subject: issue).resolved_at).to be_present
  end

  it "deduplicates by issue" do
    2.times { described_class.call(scope: [ issue ]) }

    expect(Notification.where(source: "pr_followup_limit_reached", subject: issue).count).to eq(1)
  end
end
