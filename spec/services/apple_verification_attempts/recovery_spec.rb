# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-014
RSpec.describe AppleVerificationAttempts::Recovery do
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

  it "marks stale running attempts as timed_out and is idempotent across repeated calls" do
    stale = running_attempt(started_at: clock - 46.minutes)

    first = described_class.call(timeout_monitor: AppleVerificationAttempts::TimeoutMonitor.new(clock: clock))
    second = described_class.call(timeout_monitor: AppleVerificationAttempts::TimeoutMonitor.new(clock: clock))

    expect(first.reclassified).to include(stale.id)
    expect(second.reclassified).to be_empty
    expect(stale.reload.status).to eq("timed_out")
  end

  it "invokes the durable ledger reconciler for orphaned VM recovery" do
    reconciler = instance_double(ExecutionRunners::ResourceReconciler)
    expect(reconciler).to receive(:call).and_return(enqueued: 0, cleaned: 0, failed: 0)

    result = described_class.call(
      timeout_monitor: AppleVerificationAttempts::TimeoutMonitor.new(clock: clock),
      ledger_reconciler: reconciler
    )

    expect(result.orphans).to include(:cleaned, :failed)
  end

  it "logs and absorbs ledger reconciler failures so restart loops stay idempotent" do
    reconciler = instance_double(ExecutionRunners::ResourceReconciler)
    allow(reconciler).to receive(:call).and_raise(StandardError, "host offline")

    result = described_class.call(
      timeout_monitor: AppleVerificationAttempts::TimeoutMonitor.new(clock: clock),
      ledger_reconciler: reconciler
    )

    expect(result.orphans).to eq(enqueued: 0, cleaned: 0, failed: 0)
  end
end
