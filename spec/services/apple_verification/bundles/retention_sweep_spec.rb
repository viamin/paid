# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-006
RSpec.describe AppleVerification::Bundles::RetentionSweep do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }

  let(:storage) { instance_double(AppleVerification::ArtifactIngestion::Storage) }
  let(:revocation) { instance_double(AppleVerification::Revocation::Enforce) }

  before do
    allow(storage).to receive(:delete_key)
    allow(revocation).to receive(:revoke_retained!).and_return(
      AppleVerification::Revocation::Enforce::Result.new(outcome: "verification_vm_revoked", retained_until: nil, audit_event: nil)
    )
  end

  it "deletes only the bundle key and clears the retention deadline when expired" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.minute.ago)

    result = described_class.call(storage: storage, revocation: revocation)

    expect(result.bundles_deleted).to eq(1)
    expect(storage).to have_received(:delete_key).with(
      AppleVerification::ArtifactIngestion::Storage.bundle_key(
        account_id: attempt.account_id, project_id: attempt.project_id, attempt_id: attempt.id
      )
    )
    expect(storage).not_to have_received(:delete_prefix) if storage.respond_to?(:delete_prefix)
    expect(attempt.reload.bundle_retained_until).to be_nil
  end

  it "revokes retained failed VMs and clears the retention deadline when expired" do
    attempt = create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      status: "failed",
      container_retained_until: 1.minute.ago)

    result = described_class.call(storage: storage, revocation: revocation)

    expect(result.vms_revoked).to eq(1)
    expect(revocation).to have_received(:revoke_retained!)
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

    result = described_class.call(storage: storage, revocation: revocation)

    expect(result.bundles_deleted).to eq(0)
    expect(result.vms_revoked).to eq(0)
    expect(storage).not_to have_received(:delete_key)
    expect(revocation).not_to have_received(:revoke_retained!)
  end

  it "is idempotent across repeated invocations" do
    create(:apple_verification_attempt,
      apple_verification_workflow_revision: workflow_revision,
      project: project,
      account: account,
      bundle_retained_until: 1.minute.ago)

    described_class.call(storage: storage, revocation: revocation)
    second = described_class.call(storage: storage, revocation: revocation)

    expect(second.bundles_deleted).to eq(0)
    expect(storage).to have_received(:delete_key).once
  end
end
