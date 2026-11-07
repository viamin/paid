# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-004
RSpec.describe TrustedMeasurements::Escalate do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :closed, project:, github_number: 4812) }
  let(:check_key) { "agent_planning_hold_reconciliation_closed_count" }

  it "names an unavailable synchronized source issue in the escalation title" do
    attempt = create(:trusted_measurement_attempt, :unknown, project:, issue: nil,
      external_issue_number: 999_999, deployed_revision: "rev-1",
      failure_reason: "source_issue_not_available")

    described_class.call(attempt:)

    expect(Notification.last.title).to eq("Trusted measurement source issue is unavailable")
  end

  it "keeps distinct criteria on the same issue as distinct escalations" do
    first = create(:trusted_measurement_attempt, :unknown, project:, issue:,
      check_key:, criterion_key: "criterion-a")
    second = create(:trusted_measurement_attempt, :unknown, project:, issue:,
      check_key:, criterion_key: "criterion-b")

    described_class.call(attempt: first)
    described_class.call(attempt: second)

    notifications = Notification.where(account: project.account, subject: project)
    expect(notifications.pluck(:source)).to contain_exactly(
      described_class.source_for(check_key:, criterion_key: "criterion-a", external_issue_number: 4812),
      described_class.source_for(check_key:, criterion_key: "criterion-b", external_issue_number: 4812)
    )
  end

  it "resolves only the escalation owned by the recovered criterion" do
    recovered = create(:trusted_measurement_attempt, :unknown, project:, issue:,
      check_key:, criterion_key: "criterion-a")
    still_blocked = create(:trusted_measurement_attempt, :unknown, project:, issue:,
      check_key:, criterion_key: "criterion-b")
    described_class.call(attempt: recovered)
    described_class.call(attempt: still_blocked)

    recovered.update!(status: "succeeded", result: {
      "active_total" => 0, "active_closed_issue_count" => 0
    })
    described_class.call(attempt: recovered)

    expect(Notification.active.where(account: project.account).pluck(:source)).to contain_exactly(
      described_class.source_for(check_key:, criterion_key: "criterion-b", external_issue_number: 4812)
    )
  end

  it "does not let an unauthorized check mask an unavailable source issue" do
    described_class.unauthorized(project:, check_key: "not_allowlisted",
      external_issue_number: 4812, criterion_key: "criterion-a")
    attempt = create(:trusted_measurement_attempt, :unknown, project:, issue: nil,
      check_key:, criterion_key: "criterion-a", external_issue_number: 999_999,
      deployed_revision: "rev-1", failure_reason: "source_issue_not_available")

    described_class.call(attempt:)

    expect(Notification.active.where(account: project.account).pluck(:title)).to contain_exactly(
      "Trusted measurement check is not allowlisted",
      "Trusted measurement source issue is unavailable"
    )
  end
end
