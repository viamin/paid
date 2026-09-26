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

    lifecycle = instance_double(AppleVerification::Lifecycle)
    expect(lifecycle).to receive(:destroy).with(attempt: attempt, request_id: "complete:#{attempt.id}").and_return(:destroyed)

    result = described_class.call(attempt: attempt, revocation: revocation, lifecycle: lifecycle)

    expect(result.outcome).to eq("verification_vm_destroyed")
    expect(result.retained_until).to be_nil
    expect(result.destroy_request_id).to eq("complete:#{attempt.id}")
    expect(attempt.reload.finalized_at).to be_present
  end

  it "revokes credentials when no lifecycle is available without recording a fake destroy" do
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    expect(revocation).to receive(:revoke_credential!).once

    result = described_class.call(attempt: attempt, revocation: revocation, lifecycle: nil)

    expect(result.outcome).to eq("succeeded")
    expect(result.retained_until).to be_nil
    expect(result.destroy_request_id).to be_nil
    expect(attempt.reload.finalized_at).to be_nil
  end

  it "revokes credentials and finalizes the attempt when the lifecycle reports the destroy as a no-op" do
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    expect(revocation).to receive(:revoke_credential!).once
    expect(revocation).to receive(:persist_bundle_retention!).once

    lifecycle = instance_double(AppleVerification::Lifecycle)
    expect(lifecycle).to receive(:destroy).with(attempt: attempt, request_id: "complete:#{attempt.id}").and_return(:noop)

    result = described_class.call(attempt: attempt, revocation: revocation, lifecycle: lifecycle)

    expect(result.outcome).to eq("succeeded")
    expect(result.destroy_request_id).to be_nil
    expect(attempt.reload.finalized_at).to be_present
  end

  it "persists the bundle retention deadline when an uncommitted attempt's destroy reports a no-op" do
    lifecycle = instance_double(AppleVerification::Lifecycle)
    expect(lifecycle).to receive(:destroy).with(attempt: attempt, request_id: "complete:#{attempt.id}").and_return(:noop)

    result = described_class.call(attempt: attempt, lifecycle: lifecycle)

    expect(result.outcome).to eq("succeeded")
    expect(attempt.reload.finalized_at).to be_present
    expect(attempt.bundle_retained_until).to be_present
  end

  it "revokes credentials and leaves finalization for the next sweep when the destroy raises" do
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    expect(revocation).to receive(:revoke_credential!).once

    lifecycle = instance_double(AppleVerification::Lifecycle)
    expect(lifecycle).to receive(:destroy)
      .with(attempt: attempt, request_id: "complete:#{attempt.id}")
      .and_raise(AppleVerification::HostService::UnsupportedRequestError, "workers disabled")

    result = described_class.call(attempt: attempt, revocation: revocation, lifecycle: lifecycle)

    expect(result.outcome).to eq("succeeded")
    expect(attempt.reload.finalized_at).to be_nil
  end

  it "persists the failed-VM retention window for failed attempts that hold a live VM" do
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
    create(
      :execution_resource_ledger_entry,
      account: failed.account, project: failed.project, apple_verification_attempt: failed,
      runner_type: "apple_tart", resource_kind: "verification_vm", status: "active",
      tags: {}, runner_handle: {}
    )

    result = described_class.call(attempt: failed)

    expect(result.outcome).to eq("verification_vm_retained")
    expect(failed.reload.container_retained_until).to be_present
  end

  it "revokes credentials without a VM retention window for a failed attempt with no VM" do
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
    expect(result.retained_until).to be_nil
    expect(failed.reload.container_retained_until).to be_nil
    expect(failed.bundle_retained_until).to be_present
    expect(failed.reload.finalized_at).to be_present
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

  it "skips revocation and keeps the retention deadline when the lifecycle reports the early destroy as a no-op" do
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

    revocation = instance_double(AppleVerification::Revocation::Enforce)
    expect(revocation).not_to receive(:revoke_retained!)

    lifecycle = instance_double(AppleVerification::Lifecycle)
    expect(lifecycle).to receive(:destroy).with(attempt: failed, request_id: "early_destroy:#{failed.id}").and_return(:noop)

    result = described_class.new(attempt: failed, revocation: revocation, lifecycle: lifecycle).early_destroy_retained_vm

    expect(result.outcome).to eq("failed")
    expect(result.retained_until).to be_present
    expect(result.destroy_request_id).to be_nil
    expect(failed.reload.container_retained_until).to be_present
  end

  it "keeps the retention deadline when an early destroy raises" do
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
    expect(lifecycle).to receive(:destroy)
      .with(attempt: failed, request_id: "early_destroy:#{failed.id}")
      .and_raise(Faraday::Error.new("host down"))

    result = described_class.new(attempt: failed, lifecycle: lifecycle).early_destroy_retained_vm

    expect(result.outcome).to eq("failed")
    expect(result.retained_until).to be_present
    expect(failed.reload.container_retained_until).to be_present
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
