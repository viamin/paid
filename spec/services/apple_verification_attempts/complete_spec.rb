# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-006
RSpec.describe AppleVerificationAttempts::Complete do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:attempt) { create(:apple_verification_attempt, :succeeded, project: project, account: account) }

  it "is a no-op for attempts that have not reached a terminal state" do
    live_attempt = create(:apple_verification_attempt, project: project, account: account, status: "running")

    result = described_class.call(attempt: live_attempt)

    expect(result.outcome).to eq("no_vm_to_finalize")
  end

  it "marks a successful attempt as destroyed and clears the retention deadline" do
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    expect(revocation).to receive(:call).once

    result = described_class.call(attempt: attempt, revocation: revocation)

    expect(result.outcome).to eq("verification_vm_destroyed")
    expect(result.retained_until).to be_nil
  end

  it "persists the failed-VM retention window for failed attempts" do
    failed = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      apple_worker_profile: attempt.apple_worker_profile,
      status: "failed", failure_classification: "test_assertion",
      lifecycle_gate: attempt.lifecycle_gate,
      source_digest: attempt.source_digest,
      finished_at: Time.current
    )

    result = described_class.call(attempt: failed)

    expect(result.outcome).to eq("verification_vm_retained")
    expect(failed.reload.container_retained_until).to be_present
  end

  it "uses an injected lifecycle boundary to drive early destroy and records the request id" do
    failed = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      apple_worker_profile: attempt.apple_worker_profile,
      status: "failed", failure_classification: "test_assertion",
      lifecycle_gate: attempt.lifecycle_gate,
      source_digest: attempt.source_digest,
      finished_at: Time.current
    )
    failed.update!(container_retained_until: 1.hour.from_now)

    lifecycle = instance_double(AppleVerification::Lifecycle)

    expect(lifecycle).to receive(:destroy).with(attempt: failed, request_id: "early_destroy:#{failed.id}").and_return(:destroyed)

    result = described_class.new(attempt: failed, lifecycle: lifecycle).early_destroy_retained_vm

    expect(result.outcome).to eq("verification_vm_destroyed")
    expect(result.destroy_request_id).to eq("early_destroy:#{failed.id}")
    expect(failed.reload.container_retained_until).to be_nil
  end

  it "raises when no lifecycle is available for an early destroy" do
    failed = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      apple_worker_profile: attempt.apple_worker_profile,
      status: "failed", failure_classification: "test_assertion",
      lifecycle_gate: attempt.lifecycle_gate,
      source_digest: attempt.source_digest,
      finished_at: Time.current
    )

    expect {
      described_class.new(attempt: failed, lifecycle: nil).early_destroy_retained_vm
    }.to raise_error(AppleVerificationAttempts::Complete::NoLifecycleError)
  end
end
