# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::PrFollowupLimitReached do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, max_pr_followup_runs: 3) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42,
      pr_review_phase: "ready", pr_followup_count: 3)
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(issue).to receive(:pr_escalation_worthy?)
      .with(limit: project.max_pr_followup_runs)
      .and_return(true)
    allow(issue).to receive(:consecutive_unsuccessful_pr_runs).and_return(3)
  end

  it "publishes when the follow-up limit is reached" do
    expect {
      described_class.call(scope: [ issue ])
    }.to change(Notification, :count).by(1)
  end

  it "does not publish below the threshold" do
    allow(issue).to receive(:pr_escalation_worthy?)
      .with(limit: project.max_pr_followup_runs)
      .and_return(false)

    expect {
      described_class.call(scope: [ issue ])
    }.not_to change(Notification, :count)
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
