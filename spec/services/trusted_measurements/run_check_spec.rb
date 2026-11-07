# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-003 TRUSTED-MEASUREMENTS-004 TRUSTED-MEASUREMENTS-005
RSpec.describe TrustedMeasurements::RunCheck do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :closed, project:, github_number: 4812) }
  let(:check_key) { "agent_planning_hold_reconciliation_closed_count" }
  let(:criterion_key) { "closed_planning_hold_notifications_cleared" }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  def call(key: check_key, number: issue.github_number, expected_deployed_revision: "rev-1")
    described_class.call(
      project:, check_key: key, external_issue_number: number, criterion_key:, expected_deployed_revision:
    )
  end

  def call_ignoring_failure(key: check_key, number: issue.github_number)
    call(key:, number:)
  rescue ActiveRecord::StatementInvalid
    nil
  end

  def escalation_notifications
    Notification.where(account: project.account)
      .where("source LIKE ?", "#{TrustedMeasurements::Escalate::SOURCE}/%")
  end

  it "persists a succeeded attempt bound to the deployed revision when the signal is present" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"

    attempt = call

    expect(attempt).to have_attributes(status: "succeeded", deployed_revision: "rev-1", failure_reason: nil)
    expect(attempt.result["baseline"]).to eq(36)
    expect(attempt.result["target"]).to eq(0)
  end

  it "records unknown status with a recovery reason when the deployment signal is missing, without fabricating a pass" do
    ENV["PAID_DEPLOYED_REVISION"] = nil
    expect(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).not_to receive(:call)

    attempt = call

    expect(attempt).to have_attributes(status: "unknown", deployed_revision: nil, failure_reason: "missing_deployment_signal")
    expect(attempt.issue).to eq(issue)
  end

  # @spec TRUSTED-MEASUREMENTS-004
  it "records stale deployment without running the check when the target revision is not deployed" do
    ENV["PAID_DEPLOYED_REVISION"] = "pre-fix-revision"
    expect(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).not_to receive(:call)

    attempt = call(expected_deployed_revision: "target-fix-revision")

    expect(attempt).to have_attributes(
      status: "unknown", deployed_revision: "pre-fix-revision", failure_reason: "stale_deployment"
    )
  end

  it "records an inspectable unknown attempt when the source issue is unavailable" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"

    attempt = call(number: 999_999)

    expect(attempt).to have_attributes(status: "unknown", failure_reason: "source_issue_not_available", issue: nil)
  end

  it "attaches a source issue synchronized after the initial attempt" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    first = call(number: 999_999)
    synchronized_issue = create(:issue, :closed, project:, github_number: 999_999)

    retried = call(number: 999_999)

    expect(retried.id).to eq(first.id)
    expect(retried).to have_attributes(status: "succeeded", issue: synchronized_issue)
    expect(TrustedMeasurementAttempt.count).to eq(1)
    expect(escalation_notifications.active).to be_empty
  end

  it "is idempotent for repeated calls against the same deployed revision" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"

    first = call
    second = call

    expect(second.id).to eq(first.id)
    expect(TrustedMeasurementAttempt.count).to eq(1)
  end

  it "does not create duplicate rows for duplicate events against a missing deployment signal" do
    ENV["PAID_DEPLOYED_REVISION"] = nil

    2.times { call }

    expect(TrustedMeasurementAttempt.count).to eq(1)
  end

  it "creates a new attempt for a new deployed revision instead of reinterpreting the stale one as current" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    stale = call

    ENV["PAID_DEPLOYED_REVISION"] = "rev-2"
    current = call

    expect(current.id).not_to eq(stale.id)
    expect(stale.reload.current_for_revision?("rev-2")).to be(false)
    expect(current.current_for_revision?("rev-2")).to be(true)
  end

  it "clears a prior result and never reports succeeded when a retry raises" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    successful_attempt = call
    expect(successful_attempt.result).not_to be_empty

    allow(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect { call }.to raise_error(ActiveRecord::StatementInvalid)

    attempt = TrustedMeasurementAttempt.last
    expect(attempt.status).to eq("failed")
    expect(attempt.result).to eq({})
    expect(attempt.consecutive_failure_count).to eq(1)
  end

  it "does not persist an attempt row for a check key outside the allowlist" do
    expect(call(key: "drop_all_tables")).to be_nil
    expect(TrustedMeasurementAttempt.count).to eq(0)
  end

  it "publishes a blocking escalation notification for an unauthorized check key" do
    call(key: "drop_all_tables")

    notification = escalation_notifications.first
    expect(notification).to be_blocking
    expect(notification.title).to include("not allowlisted")
  end

  it "escalates a missing deployment signal immediately, since Paid cannot recover from it on its own" do
    ENV["PAID_DEPLOYED_REVISION"] = nil

    call

    notification = escalation_notifications.first
    expect(notification).to be_active
    expect(notification).to be_blocking
    expect(notification.title).to include("revision is unknown")
  end

  it "reuses the same escalation notification across repeated missing-signal runs instead of duplicating it" do
    ENV["PAID_DEPLOYED_REVISION"] = nil

    2.times { call }

    expect(escalation_notifications.count).to eq(1)
  end

  it "escalates only after persistent execution failure, not a single transient one" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    allow(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")

    2.times { call_ignoring_failure }

    expect(escalation_notifications.active).to be_empty

    call_ignoring_failure

    expect(escalation_notifications.active).not_to be_empty
  end

  it "resolves a prior failure escalation once the check succeeds again" do
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    allow(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")
    3.times { call_ignoring_failure }
    expect(escalation_notifications.active).not_to be_empty

    allow(TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount).to receive(:call).and_call_original
    call

    expect(escalation_notifications.active).to be_empty
  end
end
