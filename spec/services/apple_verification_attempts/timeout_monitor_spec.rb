# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-004
RSpec.describe AppleVerificationAttempts::TimeoutMonitor do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:clock) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  def running_attempt(started_at:)
    create(
      :apple_verification_attempt,
      project: project, account: account,
      status: "running",
      started_at: started_at
    )
  end

  it "marks attempts whose runtime exceeds the configured timeout as timed_out" do
    # Use the same approved workflow revision across both attempts so the
    # second approve! does not supersede the first workflow and break the
    # attempt's binding.
    workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account
    )
    stale, fresh = setup_stale_and_fresh(workflow)

    described_class.call(timeout_minutes: 45, clock: clock)

    expect(stale.reload.status).to eq("timed_out")
    expect(stale.failure_classification).to eq("cancellation_or_timeout")
    expect(fresh.reload.status).to eq("running")
  end

  def setup_stale_and_fresh(workflow)
    stale = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      status: "running",
      started_at: clock - 46.minutes,
      lifecycle_gate: workflow.lifecycle_gate
    )
    fresh = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      status: "running",
      started_at: clock - 10.minutes,
      lifecycle_gate: workflow.lifecycle_gate
    )
    [ stale, fresh ]
  end

  it "does not mark timed-out attempts that have not started yet" do
    pending = create(
      :apple_verification_attempt,
      project: project, account: account,
      status: "queued",
      started_at: nil
    )

    described_class.call(timeout_minutes: 45, clock: clock)

    expect(pending.reload.status).to eq("queued")
  end

  it "ignores terminal attempts even when started_at would otherwise have been stale" do
    workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account
    )
    attempt = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      status: "running",
      started_at: clock - 2.hours,
      lifecycle_gate: workflow.lifecycle_gate
    )
    attempt.update!(status: "succeeded", finished_at: clock)

    described_class.call(timeout_minutes: 45, clock: clock)

    expect(attempt.reload.status).to eq("succeeded")
    expect(attempt.failure_classification).to be_nil
  end

  it "honors an operator-configurable timeout window" do
    workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account
    )
    ninety_minutes_old = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      status: "running",
      started_at: clock - 95.minutes,
      lifecycle_gate: workflow.lifecycle_gate
    )

    described_class.call(timeout_minutes: 120, clock: clock)

    expect(ninety_minutes_old.reload.status).to eq("running")
  end

  it "exposes the deadline for a started_at so callers can stamp the attempt consistently" do
    monitor = described_class.new(timeout_minutes: 45, clock: clock)

    expect(monitor.deadline_for(clock)).to eq(clock + 45.minutes)
  end

  it "reports scanned counts before reclassification so the metric reflects the original candidate set" do
    workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account
    )
    stale_one = create_stale_attempt(workflow, clock - 46.minutes)
    stale_two = create_stale_attempt(workflow, clock - 60.minutes)

    result = described_class.call(timeout_minutes: 45, clock: clock)

    expect(result.scanned).to eq(2)
    expect(result.timed_out).to contain_exactly(stale_one.id, stale_two.id)
  end

  def create_stale_attempt(workflow, started_at)
    create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      status: "running",
      started_at: started_at,
      lifecycle_gate: workflow.lifecycle_gate
    )
  end
end
