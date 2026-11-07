# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PilotMetrics do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:other_project) { create(:project, account:) }
  let(:window_started_at) { 14.days.ago }
  let(:window_ended_at) { Time.current }

  def decided_notification(subject:, created_at:, resolved_at: nil, dismissed_at: nil, metadata: {})
    create(:notification,
      account:,
      subject:,
      severity: :error,
      blocking: true,
      created_at: created_at,
      resolved_at: resolved_at,
      dismissed_at: dismissed_at,
      metadata: metadata)
  end

  def metrics
    described_class.call(project:, window_started_at:, window_ended_at:)
  end

  it "counts human Inbox decisions per completed issue over the window" do
    issues = create_list(:issue, 3, project:, paid_state: "completed")
    issues.each do |issue|
      decided_notification(subject: issue, created_at: 2.days.ago, resolved_at: 1.day.ago)
    end
    decided_notification(subject: project, created_at: 2.days.ago, dismissed_at: 1.day.ago)
    decided_notification(subject: project, created_at: 3.days.ago, resolved_at: 2.days.ago)

    result = metrics

    expect(result.inbox_decisions).to eq(5)
    expect(result.completed_issues).to eq(3)
    expect(result.decisions_per_completed_issue).to be_within(0.001).of(5 / 3.0)
  end

  it "ignores undecided, out-of-window, and out-of-scope decisions" do
    issue = create(:issue, project:, paid_state: "completed")
    decided_notification(subject: issue, created_at: 2.days.ago, resolved_at: nil) # still active
    decided_notification(subject: issue, created_at: 30.days.ago, resolved_at: 29.days.ago) # outside window
    decided_notification(subject: create(:issue, project: other_project), created_at: 2.days.ago, resolved_at: 1.day.ago)
    create(:notification, subject: issue, severity: :warning, blocking: false,
      created_at: 2.days.ago, resolved_at: 1.day.ago) # not a human-decision notification

    result = metrics

    expect(result.inbox_decisions).to eq(0)
  end

  it "excludes automatically released decisions with a reason code" do
    issue = create(:issue, project:, paid_state: "completed")
    decided_notification(subject: issue, created_at: 2.days.ago, resolved_at: 1.day.ago)
    decided_notification(subject: issue, created_at: 2.days.ago, resolved_at: 1.day.ago,
      metadata: { "released_by" => "reconciled_evidence" })

    result = metrics

    expect(result.inbox_decisions).to eq(1)
    expect(result.exclusions).to include({ "reason" => "auto_released", "count" => 1 })
  end

  it "reports median and p90 human decision time" do
    issue = create(:issue, project:, paid_state: "completed")
    decided_notification(subject: issue, created_at: 10.minutes.ago, resolved_at: 4.minutes.ago)
    decided_notification(subject: issue, created_at: 30.minutes.ago, resolved_at: 10.minutes.ago)
    decided_notification(subject: issue, created_at: 1.hour.ago, dismissed_at: 10.minutes.ago)

    result = metrics

    expect(result.median_decision_seconds).to eq(1200.0)
    expect(result.p90_decision_seconds).to eq(3000.0)
  end

  it "reports the completed-issue rate over issues admitted in the window" do
    delivered = create_list(:issue, 4, project:, paid_state: "completed")
    delivered.each { |issue| create(:agent_run, project:, issue:, created_at: 2.days.ago) }
    unfinished = create(:issue, project:, paid_state: "in_progress")
    create(:agent_run, project:, issue: unfinished, created_at: 2.days.ago)
    create(:agent_run, project:, issue: create(:issue, project:, paid_state: "completed",
      updated_at: 30.days.ago), created_at: 30.days.ago) # completed and admitted before the window

    result = metrics

    expect(result.admitted_issues).to eq(5)
    expect(result.completed_issues).to eq(4)
    expect(result.completed_issue_rate).to be_within(0.001).of(0.8)
  end

  it "counts settled completions later reversed, with delegated attribution" do
    completed = create_list(:issue, 4, project:, paid_state: "completed")
    reopened = create(:issue, project:,
      paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    create(:bounded_delegated_action, project:, issue: reopened, created_at: 20.days.ago)
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: "parked for an unrelated reason")
    completed # keep the completed population non-empty

    result = metrics

    expect(result.reversal_count).to eq(1)
    expect(result.reversal_rate).to be_within(0.001).of(0.25)
    expect(result.delegated_reversal_count).to eq(1)
  end

  it "does not attribute reversals to delegated work without an authorization" do
    create(:issue, project:, paid_state: "completed")
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = metrics

    expect(result.reversal_count).to eq(1)
    expect(result.delegated_reversal_count).to eq(0)
  end

  it "pins the intent revisions of the joined work items" do
    issue = create(:issue, project:, paid_state: "completed")
    admitted = create(:issue, project:, paid_state: "in_progress")
    create(:agent_run, project:, issue: admitted, created_at: 2.days.ago)

    result = metrics
    digest = result.revisions.fetch("issues_digest")
    joined = result.revisions.fetch("joined_issue_ids")

    expect(joined).to contain_exactly(issue.id, admitted.id)
    expect(digest).to be_present

    issue.update!(title: "A materially different request")

    refreshed = described_class.call(project:, window_started_at:, window_ended_at:)

    expect(refreshed.revisions.fetch("issues_digest")).not_to eq(digest)
  end

  it "returns nil ratios instead of dividing by zero" do
    result = metrics

    expect(result.completed_issues).to eq(0)
    expect(result.decisions_per_completed_issue).to be_nil
    expect(result.completed_issue_rate).to be_nil
    expect(result.reversal_rate).to be_nil
    expect(result.median_decision_seconds).to be_nil
    expect(result.p90_decision_seconds).to be_nil
  end
end
