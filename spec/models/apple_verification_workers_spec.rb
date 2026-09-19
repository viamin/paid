# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Apple verification persistence", type: :model do
  let(:digest) { "sha256:#{'e' * 64}" }

  it "persists only the three project modes" do # @spec APPLE-WORKER-003
    project = create(:project, apple_verification_mode: "automatic")

    expect(project).to be_valid
    expect(build(:project, apple_verification_mode: "host")).not_to be_valid
  end

  it "does not permit a profile contract to change after registration" do # @spec APPLE-WORKER-001
    profile = create(:apple_worker_profile)

    profile.constraints = { "platforms" => [ "macos" ], "xcode_version" => ">= 26.0" }

    expect(profile).not_to be_valid
    expect(profile.errors[:base]).to include("worker profile constraints are immutable")
  end

  it "binds and freezes approval inputs while superseding the prior approval" do # @spec APPLE-WORKER-004
    project = create(:project)
    actor = create(:user, account: project.account)
    old_revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    old_revision.approve!(actor:)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)

    revision.approve!(actor:)
    revision.content_digest = digest

    expect(old_revision.reload).to be_superseded
    expect(revision).not_to be_valid
    expect(revision.errors[:base]).to include("approved workflow binding is immutable")
  end

  it "requires waiver ownership and bindings to match one attempt" do # @spec APPLE-WORKER-005 @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    waiver = AppleVerificationWaiver.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: create(:user, account: attempt.account), source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate, check_ids: [ "test" ], reason: "Known simulator outage", expires_at: 1.hour.from_now
    )

    expect(waiver).to be_valid
    expect { waiver.save! }.to change(AppleVerificationWaiver, :count).by(1)
  end

  it "keeps Apple audit and VM-ledger ownership bound to the attempt" do # @spec APPLE-WORKER-007
    attempt = create(:apple_verification_attempt)
    ledger = ExecutionResourceLedgerEntry.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      runner_type: "apple_verification", resource_kind: "verification_vm", status: "provisioning", tags: {}, runner_handle: {}
    )
    event = ExecutionAuditEvent.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      event_name: "apple.verification_started", event_version: 1, credential_classes: [], network_policy: {}, metadata: {}
    )

    expect(ledger).to be_valid
    expect(event).to be_valid
  end
end
