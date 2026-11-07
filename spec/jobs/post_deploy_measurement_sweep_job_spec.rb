# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-004
# @spec POST-DEPLOY-009
RSpec.describe PostDeployMeasurementSweepJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:check) { PostDeployMeasurements::Registry.find("planning_hold_notifications_actionable") }

  def deploy_merged_pr!(at: Time.current)
    pr = create(:issue, :pull_request, :closed, project: project, github_number: 7,
      pr_review_phase: "merged", parent_issue_id: issue.id)
    pr.update!(deployed_at: at)
    pr
  end

  def prerequisite_notification(identity: "identity-a")
    create(:notification, account: account, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      subject: issue, severity: :error, blocking: true,
      metadata: { "prerequisites" => [ { "identity" => identity, "criterion" => "Record the live count",
                                         "kind" => "human" } ] })
  end

  it "enqueues due measurements for execution" do
    due = create(:post_deploy_measurement, issue: issue, project: project, status: "pending")
    exhausted = create(:post_deploy_measurement, issue: issue, project: project, status: "unknown", attempts: 3,
      deployed_revision: "pr-1@2026-11-07T00:00:00Z")

    allow(PostDeployMeasurementJob).to receive(:perform_later)

    described_class.new.perform

    expect(PostDeployMeasurementJob).to have_received(:perform_later).with(due.id)
    expect(PostDeployMeasurementJob).not_to have_received(:perform_later).with(exhausted.id)
  end

  it "re-requests evidence when the deployment generation moved and the prerequisite is still active" do
    deploy_merged_pr!(at: 2.days.ago)
    prerequisite_notification
    executed = PostDeployMeasurements::Request.call(issue: issue, check_key: check.key,
      criterion: "criterion", prerequisite_identity: "identity-a").measurement
    executed.update!(status: "passed", deployed_revision: "pr-7@#{2.days.ago.utc.iso8601}",
      executed_at: Time.current)
    deploy_merged_pr!(at: Time.current)

    allow(PostDeployMeasurementJob).to receive(:perform_later)
    described_class.new.perform

    fresh = issue.post_deploy_measurements.where(deployed_revision: "").order(id: :desc).first
    expect(fresh).to be_present
    expect(fresh.prerequisite_identity).to eq("identity-a")
    expect(fresh).to have_attributes(status: "pending")
  end

  it "stops re-requesting evidence whose prerequisite was already released" do
    deploy_merged_pr!(at: 2.days.ago)
    notification = prerequisite_notification
    executed = PostDeployMeasurements::Request.call(issue: issue, check_key: check.key,
      criterion: "criterion", prerequisite_identity: "identity-a").measurement
    executed.update!(status: "passed", deployed_revision: "pr-7@#{2.days.ago.utc.iso8601}",
      released_at: Time.current, executed_at: Time.current)
    notification.update!(resolved_at: Time.current)
    deploy_merged_pr!(at: Time.current)

    allow(PostDeployMeasurements::Request).to receive(:call)
    allow(PostDeployMeasurementJob).to receive(:perform_later)

    described_class.new.perform

    expect(PostDeployMeasurements::Request).not_to have_received(:call)
  end

  it "does not re-request when a terminal measurement is already current" do
    pr = deploy_merged_pr!
    prerequisite_notification
    executed = PostDeployMeasurements::Request.call(issue: issue, check_key: check.key,
      criterion: "criterion", prerequisite_identity: "identity-a").measurement
    executed.update!(status: "passed",
      deployed_revision: "pr-7@#{pr.deployed_at.utc.iso8601}", executed_at: Time.current)

    allow(PostDeployMeasurements::Request).to receive(:call)
    allow(PostDeployMeasurementJob).to receive(:perform_later)

    described_class.new.perform

    expect(PostDeployMeasurements::Request).not_to have_received(:call)
  end
end
