# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-006
RSpec.describe AppleVerification::Revocation::Enforce do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }
  let(:credential_lane) { instance_double(AppleVerification::SourceLane::CredentialLane) }

  before { allow(credential_lane).to receive(:revoke!) }

  it "records the VM destruction audit event and revokes credentials on success" do
    attempt.update!(status: "succeeded")

    expect {
      described_class.call(attempt: attempt, credential_lane: credential_lane, bundle_retention_days: 7)
    }.to change { ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed").count }.by(1)
      .and change { ExecutionAuditEvent.where(event_name: "apple_credential.revoked").count }.by(1)

    expect(credential_lane).to have_received(:revoke!)
    expect(attempt.reload.container_retained_until).to be_nil
    expect(attempt.bundle_retained_until).to be_nil
  end

  it "persists the bundle retention deadline for an uncommitted successful attempt" do
    uncommitted = create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
    uncommitted.update!(status: "succeeded")

    described_class.call(attempt: uncommitted, credential_lane: credential_lane, bundle_retention_days: 7)

    expect(uncommitted.reload.bundle_retained_until).to be_within(2.seconds).of(7.days.from_now)
  end

  it "leaves bundle_retained_until nil for a committed successful attempt" do
    committed = create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
    committed.update!(status: "succeeded")

    described_class.call(attempt: committed, credential_lane: credential_lane, bundle_retention_days: 7)

    expect(committed.reload.bundle_retained_until).to be_nil
  end

  it "retains the failed VM and persists the retention deadline" do
    attempt.update!(status: "failed", finished_at: Time.current)

    expect {
      described_class.call(attempt: attempt, credential_lane: credential_lane, failed_vm_retention_hours: 1, bundle_retention_days: 7)
    }.to change { ExecutionAuditEvent.where(event_name: "apple_verification_vm.retained").count }.by(1)

    attempt.reload
    expect(attempt.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
    expect(attempt.bundle_retained_until).to be_nil
    expect(credential_lane).to have_received(:revoke!)
  end

  it "leaves bundle_retained_until nil for a committed failed attempt" do
    committed = create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
    committed.update!(status: "failed", finished_at: Time.current)

    described_class.call(attempt: committed, credential_lane: credential_lane, failed_vm_retention_hours: 1, bundle_retention_days: 7)

    committed.reload
    expect(committed.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
    expect(committed.bundle_retained_until).to be_nil
  end

  it "records the VM destruction audit event and clears the retention deadline for a retained VM" do
    attempt.update!(status: "failed", finished_at: Time.current, container_retained_until: 1.minute.ago)

    expect {
      described_class.new(attempt: attempt, credential_lane: credential_lane).revoke_retained!
    }.to change { ExecutionAuditEvent.where(event_name: "apple_verification_vm.destroyed").count }.by(1)

    expect(attempt.reload.container_retained_until).to be_nil
    expect(credential_lane).to have_received(:revoke!)
  end

  it "does not record a credential revocation audit event for an uncommitted attempt" do
    uncommitted = create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
    uncommitted.update!(status: "succeeded")

    expect {
      described_class.call(attempt: uncommitted, credential_lane: credential_lane)
    }.not_to change { ExecutionAuditEvent.where(event_name: "apple_credential.revoked").count }

    expect(credential_lane).not_to have_received(:revoke!)
  end

  it "does not record a credential revocation audit event for an uncommitted retained VM" do
    uncommitted = create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
    uncommitted.update!(status: "failed", finished_at: Time.current, container_retained_until: 1.minute.ago)

    expect {
      described_class.new(attempt: uncommitted, credential_lane: credential_lane).revoke_retained!
    }.not_to change { ExecutionAuditEvent.where(event_name: "apple_credential.revoked").count }

    expect(credential_lane).not_to have_received(:revoke!)
  end

  it "records credential revocation audit events without a token value" do
    attempt.update!(status: "succeeded")
    described_class.call(attempt: attempt, credential_lane: credential_lane)

    event = ExecutionAuditEvent.where(event_name: "apple_credential.revoked").last
    aggregate_failures do
      expect(event.metadata).not_to have_key("token")
      expect(event.metadata).not_to have_key("value")
      expect(event.metadata).not_to have_key("secret")
      expect(event.apple_verification_attempt).to eq(attempt)
      expect(event.project).to eq(project)
      expect(event.account).to eq(account)
    end
  end

  it "does nothing for non-terminal states" do
    attempt.update!(status: "running")

    expect {
      described_class.call(attempt: attempt, credential_lane: credential_lane)
    }.not_to change(ExecutionAuditEvent, :count)

    expect(credential_lane).not_to have_received(:revoke!)
  end
end
