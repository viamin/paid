# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::ScannerWedgedOnPendingReview do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) do
    create(:issue, :pull_request, project: project, github_number: 42,
      pr_review_phase: "draft", auto_continue_paused: false)
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  def pending_scope
    [ { issue_id: issue.id, pending_review: true, requested_bot: "copilot", pr_phase: issue.pr_review_phase } ]
  end

  it "publishes on the fourth consecutive pending poll" do
    freeze_time do
      3.times do |index|
        described_class.call(scope: pending_scope)
        travel 10.minutes if index < 2
      end

      expect {
        travel 10.minutes
        described_class.call(scope: pending_scope)
      }.to change(Notification, :count).by(1)
    end

    notification = Notification.find_by!(source: "scanner_wedged_on_pending_review", subject: issue)
    expect(notification.metadata["consecutive_polls"]).to eq(4)
  end

  it "does not publish before the threshold" do
    3.times { described_class.call(scope: pending_scope) }

    expect(Notification.where(source: "scanner_wedged_on_pending_review", subject: issue)).to be_empty
  end

  it "resolves when the pending trigger clears" do
    4.times { described_class.call(scope: pending_scope) }

    described_class.call(scope: [ { issue_id: issue.id, pending_review: false, pr_phase: issue.pr_review_phase } ])

    expect(Notification.find_by!(source: "scanner_wedged_on_pending_review", subject: issue).resolved_at).to be_present
    expect(NotificationRuleState.where(source: "scanner_wedged_on_pending_review", subject: issue)).to be_empty
  end

  it "deduplicates by issue" do
    5.times { described_class.call(scope: pending_scope) }

    expect(Notification.where(source: "scanner_wedged_on_pending_review", subject: issue).count).to eq(1)
  end
end
