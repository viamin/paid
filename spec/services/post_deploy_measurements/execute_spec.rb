# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-003
# @spec POST-DEPLOY-004
# @spec POST-DEPLOY-005
# @spec POST-DEPLOY-007
RSpec.describe PostDeployMeasurements::Execute do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:check) { PostDeployMeasurements::Registry.find("planning_hold_notifications_actionable") }
  let(:measurement) do
    PostDeployMeasurements::Request.call(issue: issue, check_key: check.key, criterion: check.criterion).measurement
  end

  def deploy_merged_pr!(deployed: true, number: 7, at: Time.current)
    pr = create(:issue, :pull_request, :closed, project: project, github_number: number,
      pr_review_phase: "merged", parent_issue_id: issue.id)
    pr.update!(deployed_at: at) if deployed
    pr
  end

  def planning_notification(subject, **attributes)
    create(:notification, account: account,
      source: PostDeployMeasurements::Checks::PlanningHoldNotifications::NOTIFICATION_SOURCE,
      subject: subject, severity: :error, blocking: true, **attributes)
  end

  it "records a passing measurement with counts, scope, revision, and provenance" do
    pr = deploy_merged_pr!
    planning_notification(create(:issue, project: project))
    planning_notification(create(:issue, :closed, project: project), resolved_at: Time.current)

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("passed")
    record = measurement.reload
    expect(record).to be_passed
    expect(record).to have_attributes(
      deployed_revision: "pr-7@#{pr.deployed_at.utc.iso8601}",
      deployed_pr_number: 7,
      executed_at: be_present,
      deployed_at: be_present,
      duration_ms: be >= 0,
      attempts: 1
    )
    expect(record.counts).to include("actionable_closed_source" => 0, "active_total" => 1,
      "active_open_source" => 1, "resolved_total" => 1)
    expect(record.details["comparison"]).to include("baseline" => 36, "target" => 0, "measured" => 0)
    expect(record.details["scope"]).to include("project_id" => project.id, "project" => project.full_name)
  end

  it "waits for deployment instead of fabricating a pass" do
    deploy_merged_pr!(deployed: false)

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("awaiting_deployment")
    record = measurement.reload
    expect(record).not_to be_passed
    expect(record.counts).to be_empty
    expect(record.details["next_action"]).to include("Mark merged PR #7 as deployed")
    expect(Notification.where(source: PostDeployMeasurements::ESCALATION_NOTIFICATION_SOURCE)).not_to exist
  end

  it "names a recovery action when no merged PR exists" do
    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("awaiting_deployment")
    expect(measurement.reload.details["next_action"]).to include("No merged PR is linked")
  end

  it "records a failed, escalated result when the live count contradicts the target" do
    deploy_merged_pr!
    planning_notification(create(:issue, :closed, project: project))

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("failed")
    escalation = Notification.find_by(source: PostDeployMeasurements::ESCALATION_NOTIFICATION_SOURCE, subject: issue)
    expect(escalation).to be_present
    expect(escalation).not_to be_blocking
    expect(escalation.metadata["recommended_action"]).to be_present
  end

  it "records unknown without a pass when execution fails, and escalates only after the attempt cap" do
    deploy_merged_pr!
    allow(PostDeployMeasurements::Checks::PlanningHoldNotifications).to receive(:measure)
      .and_raise(ActiveRecord::StatementInvalid.new("connection lost"))

    2.times { described_class.call(measurement: measurement.reload) }

    expect(measurement.reload.status).to eq("unknown")
    expect(measurement.reload.attempts).to eq(2)
    expect(Notification.where(source: PostDeployMeasurements::ESCALATION_NOTIFICATION_SOURCE)).not_to exist

    described_class.call(measurement: measurement.reload)

    expect(measurement.reload.attempts).to eq(3)
    escalation = Notification.find_by(source: PostDeployMeasurements::ESCALATION_NOTIFICATION_SOURCE, subject: issue)
    expect(escalation).to be_present
    expect(escalation.metadata["recommended_action"]).to include("repeatedly")
  end

  it "does not re-execute an exhausted or terminal row" do
    deploy_merged_pr!
    measurement.update!(status: "passed", deployed_revision: "pr-7@2026-11-07T00:00:00Z", executed_at: Time.current)

    expect(measurement.reload).not_to be_retryable
    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("passed")
    expect(measurement.reload.attempts).to eq(0)
  end

  it "records unknown with a recovery action when a required capability is unavailable" do
    deploy_merged_pr!
    allow(PostDeployMeasurements::Capabilities).to receive(:first_unavailable).and_return(
      PostDeployMeasurements::Capabilities::UNAVAILABLE.new("notifications", "Restore database access.")
    )

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("unknown")
    record = measurement.reload
    expect(record.failure_reason).to include("notifications")
    expect(record.details["next_action"]).to eq("Restore database access.")
    expect(Notification.where(source: PostDeployMeasurements::ESCALATION_NOTIFICATION_SOURCE, subject: issue)).to be_present
  end

  it "records unknown with a recovery action when the check version left the allowlist" do
    deploy_merged_pr!
    measurement.update!(check_version: 99)

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("unknown")
    expect(measurement.reload.failure_reason).to include("v99")
  end

  it "records an authorization failure with a recovery action for a suspended account" do
    deploy_merged_pr!
    account.update!(status: :suspended)

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("unknown")
    expect(measurement.reload.failure_reason).to include("authorization")
  end

  it "classifies a measurer that attempts a write as unknown, not passed" do
    deploy_merged_pr!
    hostile = Class.new do
      def self.measure(project:)
        Notification.create!(account: project.account, source: "hostile_write", subject: project,
          title: "written", severity: :error, blocking: false)
        PostDeployMeasurements::Checks::PlanningHoldNotifications::Result.new(
          counts: { "actionable_closed_source" => 0 }, scope: {})
      end
    end
    stub_const("HostileMeasurer", hostile)
    hostile_check = PostDeployMeasurements::Check.new(
      key: "hostile", version: 1, criterion: "hostile", baseline: 0, target: 0,
      capabilities: [], measurer: HostileMeasurer
    )
    # The registry is the allowlist seam; inject a hostile registered check to
    # prove the executor contains a buggy or hostile entry defensively.
    allow(PostDeployMeasurements::Registry).to receive(:find).with(measurement.check_key).and_return(hostile_check)

    result = described_class.call(measurement: measurement.reload)

    expect(result.status).to eq("unknown")
    expect(measurement.reload.failure_reason).to include("read-only")
  end

  it "requires a newer deployment generation instead of trusting stale evidence" do
    deployed_at = 2.days.ago.change(usec: 0)
    pr = deploy_merged_pr!(at: deployed_at)
    described_class.call(measurement: measurement.reload)
    first = measurement.reload
    expect(first).to be_passed

    # A later deployment moves the target revision: the sweep requests a
    # fresh row for the new generation rather than reusing the old evidence.
    pr.update!(deployed_at: Time.current)
    fresh = PostDeployMeasurements::Request.call(issue: issue, check_key: check.key, criterion: check.criterion).measurement

    expect(fresh.id).not_to eq(first.id)
    expect(fresh.deployed_revision).to eq("")
    expect(first.deployed_revision).to start_with("pr-7@")
    expect(first.deployed_revision).to eq("pr-7@#{deployed_at.utc.iso8601}")
    expect(first).not_to be_current_for(target_revision: fresh_target_revision(issue), check_version: check.version)
  end

  def fresh_target_revision(issue)
    PostDeployMeasurements::DeploymentTarget.resolve(issue).revision
  end
end
