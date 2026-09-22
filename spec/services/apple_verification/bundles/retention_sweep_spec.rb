# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-006
RSpec.describe AppleVerification::Bundles::RetentionSweep do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }

  let(:storage) { instance_double(AppleVerification::ArtifactIngestion::Storage) }
  let(:revocation) { instance_double(AppleVerification::Revocation::Enforce) }
  let(:lifecycle) { instance_double(AppleVerification::Lifecycle) }

  before do
    allow(storage).to receive(:delete_key)
    allow(revocation).to receive(:revoke_retained!).and_return(
      AppleVerification::Revocation::Enforce::Result.new(outcome: "verification_vm_revoked", retained_until: nil, audit_event: nil)
    )
    allow(lifecycle).to receive(:destroy).and_return(:destroyed)
  end

  it "deletes only the bundle key and clears the retention deadline when expired" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.minute.ago)

    result = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)

    expect(result.bundles_deleted).to eq(1)
    expect(storage).to have_received(:delete_key).with(
      AppleVerification::ArtifactIngestion::Storage.bundle_key(
        account_id: attempt.account_id, project_id: attempt.project_id, attempt_id: attempt.id
      )
    )
    expect(storage).not_to have_received(:delete_prefix) if storage.respond_to?(:delete_prefix)
    expect(attempt.reload.bundle_retained_until).to be_nil
  end

  it "drives the real VM destroy before recording the revocation audit event" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      status: "failed",
      container_retained_until: 1.minute.ago)

    destroy_order = []
    allow(lifecycle).to receive(:destroy) { destroy_order << :lifecycle_destroy; :destroyed }
    allow(revocation).to receive(:revoke_retained!) do
      destroy_order << :revocation_revoke
      AppleVerification::Revocation::Enforce::Result.new(outcome: "verification_vm_revoked", retained_until: nil, audit_event: nil)
    end

    result = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)

    expect(result.vms_revoked).to eq(1)
    expect(lifecycle).to have_received(:destroy).with(attempt: attempt, request_id: "retention_sweep:destroy:#{attempt.id}")
    expect(revocation).to have_received(:revoke_retained!)
    expect(destroy_order).to eq([ :lifecycle_destroy, :revocation_revoke ])
    expect(attempt.reload.container_retained_until).to be_nil
  end

  it "skips attempts whose retention deadline has not yet expired" do
    create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.hour.from_now)
    create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      status: "failed",
      container_retained_until: 1.hour.from_now)

    result = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)

    expect(result.bundles_deleted).to eq(0)
    expect(result.vms_revoked).to eq(0)
    expect(storage).not_to have_received(:delete_key)
    expect(lifecycle).not_to have_received(:destroy)
    expect(revocation).not_to have_received(:revoke_retained!)
  end

  it "is idempotent across repeated invocations" do
    create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.minute.ago)

    described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)
    second = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)

    expect(second.bundles_deleted).to eq(0)
    expect(storage).to have_received(:delete_key).once
  end

  it "records a vm_retention_sweep_failed warning when the destroy raises and keeps the deadline set" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      status: "failed",
      container_retained_until: 1.minute.ago)
    allow(lifecycle).to receive(:destroy).and_raise(StandardError, "host unreachable")

    expect {
      result = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)
      expect(result.vms_revoked).to eq(0)
    }.not_to raise_error

    expect(revocation).not_to have_received(:revoke_retained!)
    expect(attempt.reload.container_retained_until).to be_present
  end

  it "skips VM revocation when no lifecycle is available so the audit event is not recorded" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      status: "failed",
      container_retained_until: 1.minute.ago)
    allow(AppleVerification::Lifecycle).to receive(:from_environment).and_return(nil)

    result = described_class.call(storage: storage, revocation: revocation)

    expect(result.vms_revoked).to eq(0)
    expect(revocation).not_to have_received(:revoke_retained!)
    expect(attempt.reload.container_retained_until).to be_present
  end

  it "logs bundle_retention_sweep_failed and keeps the deadline when storage raises StorageError" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.minute.ago)
    allow(storage).to receive(:delete_key).and_raise(ArtifactStorage::StorageError, "S3 delete failed: AccessDenied")

    result = described_class.call(storage: storage, revocation: revocation, lifecycle: lifecycle)

    expect(result.bundles_deleted).to eq(0)
    expect(attempt.reload.bundle_retained_until).to be_present
  end
end
