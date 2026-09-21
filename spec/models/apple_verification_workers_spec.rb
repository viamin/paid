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

  it "requires profiles to use canonical image digests" do # @spec APPLE-WORKER-001
    profile = build(:apple_worker_profile, image_digest: "xcode:latest")

    expect(profile).not_to be_valid
    expect(profile.errors[:image_digest]).to be_present
  end

  it "requires a profile creator to belong to its account" do # @spec APPLE-WORKER-001
    profile = build(:apple_worker_profile, created_by: create(:user, account: create(:account)))

    expect(profile).not_to be_valid
    expect(profile.errors[:created_by]).to include("must belong to the profile account")
  end

  it "rejects persisted profiles with unsupported capabilities or platforms" do # @spec APPLE-WORKER-001
    unsupported_capability = build(:apple_worker_profile, capabilities: { "capabilities" => [ "shell" ] })
    unsupported_platform = build(:apple_worker_profile, constraints: { "platforms" => [ "windows" ], "xcode_version" => ">= 26.0" })

    expect(unsupported_capability).not_to be_valid
    expect(unsupported_capability.errors[:base]).to include("unsupported Apple worker capabilities: shell")
    expect(unsupported_platform).not_to be_valid
    expect(unsupported_platform.errors[:base]).to include("unsupported Apple platform")
  end

  it "binds and freezes approval inputs while superseding the prior approval" do # @spec APPLE-WORKER-004
    project = create(:project)
    actor = create(:user, account: project.account)
    actor.add_role(:project_admin, project)
    old_revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    old_revision.approve!(actor:)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)

    revision.approve!(actor:)
    revision.content_digest = digest

    expect(old_revision.reload).to be_superseded
    expect(revision).not_to be_valid
    expect(revision.errors[:base]).to include("approved workflow binding is immutable")
  end

  it "does not permit clearing an approval record to rewrite the binding across two saves" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    revision.approve!(actor: administrator)

    revision.assign_attributes(status: "draft", approved_by: nil, approved_at: nil)

    expect(revision).not_to be_valid
    expect(revision.errors[:base]).to include("approval actor and timestamp are immutable once set")

    revision.reload
    revision.assign_attributes(status: "superseded", approved_by: nil, approved_at: nil)

    expect(revision).not_to be_valid
    expect(revision.errors[:base]).to include("approval actor and timestamp are immutable once set")
  end

  it "does not permit an approved workflow revision to move to another project" do # @spec APPLE-WORKER-004
    project = create(:project)
    other_project = create(:project, account: project.account)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    administrator.add_role(:project_admin, other_project)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    revision.approve!(actor: administrator)

    revision.project = other_project

    expect(revision).not_to be_valid
    expect(revision.errors[:base]).to include("approved workflow binding is immutable")
  end

  it "keeps a superseded revision's approved binding immutable" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    old_revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    replacement = create(:apple_verification_workflow_revision, project:, account: project.account)

    old_revision.approve!(actor: administrator)
    replacement.approve!(actor: administrator)
    old_revision.content_digest = digest

    expect(old_revision).not_to be_valid
    expect(old_revision.errors[:base]).to include("approved workflow binding is immutable")
  end

  it "requires a project administrator to approve a workflow revision" do # @spec APPLE-WORKER-004
    project = create(:project)
    revision = create(:apple_verification_workflow_revision, project:)
    account_member = create(:user, account: project.account)
    project_member = create(:user, account: project.account)
    project_member.add_role(:project_member, project)

    expect { revision.approve!(actor: account_member) }.to raise_error(ArgumentError, /project administrator/)
    expect { revision.approve!(actor: project_member) }.to raise_error(ArgumentError, /project administrator/)
  end

  it "rejects a directly persisted approval by a non-administrator" do # @spec APPLE-WORKER-004
    project = create(:project)
    revision = build(:apple_verification_workflow_revision, project:, account: project.account, status: "approved", approved_by: create(:user, account: project.account), approved_at: Time.current)

    expect(revision).not_to be_valid
    expect(revision.errors[:approved_by]).to include("must be a project administrator")
    expect { revision.save! }.to raise_error(ActiveRecord::RecordInvalid, /project administrator/)
  end

  it "enforces one approved workflow revision per project" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    approved_revision = create(:apple_verification_workflow_revision, project:)
    competing_revision = create(:apple_verification_workflow_revision, project:)

    approved_revision.approve!(actor: administrator)
    competing_revision.approve!(actor: administrator)

    expect(project.apple_verification_workflow_revisions.approved).to contain_exactly(competing_revision)
  end

  it "does not approve a workflow revision with a non-active profile" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    profile = create(:apple_worker_profile, account: project.account, status: "deprecated")
    revision = create(:apple_verification_workflow_revision, project:, account: project.account, apple_worker_profile: profile)

    expect { revision.approve!(actor: administrator) }.to raise_error(ArgumentError, /profile must be active/)
    expect(revision).to be_draft
  end

  it "rejects a directly persisted approval with a non-active profile" do # @spec APPLE-WORKER-004
    project = create(:project)
    profile = create(:apple_worker_profile, account: project.account, status: "revoked")
    revision = build(:apple_verification_workflow_revision,
      project:,
      account: project.account,
      apple_worker_profile: profile,
      status: "approved",
      approved_by: create(:user, account: project.account).tap { |user| user.add_role(:project_admin, project) },
      approved_at: Time.current)

    expect(revision).not_to be_valid
    expect(revision.errors[:apple_worker_profile]).to include("must be active to approve")
  end

  it "requires waiver ownership and bindings to match one attempt" do # @spec APPLE-WORKER-005 @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    waiver = AppleVerificationWaiver.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: create(:user, account: attempt.account).tap { |user| user.add_role(:project_admin, attempt.project) }, source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate, check_ids: [ "test" ], reason: "Known simulator outage", expires_at: 1.hour.from_now
    )

    expect(waiver).to be_valid
    expect { waiver.save! }.to change(AppleVerificationWaiver, :count).by(1)
  end

  it "requires a project administrator to create a waiver" do # @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    waiver = AppleVerificationWaiver.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: create(:user, account: attempt.account), source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate, check_ids: [ "test" ], reason: "Known simulator outage", expires_at: 1.hour.from_now
    )

    expect(waiver).not_to be_valid
    expect(waiver.errors[:created_by]).to include("must be a project administrator")
  end

  it "requires an attempt gate to match its approved workflow" do # @spec APPLE-WORKER-005
    workflow = create(:apple_verification_workflow_revision, lifecycle_gate: "agent_iteration")
    attempt = build(:apple_verification_attempt,
      account: workflow.account,
      project: workflow.project,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      lifecycle_gate: "pull_request_verification")

    expect(attempt).not_to be_valid
    expect(attempt.errors[:lifecycle_gate]).to include("must match the workflow gate")
  end

  it "keeps an attempt's execution binding immutable while allowing lifecycle updates" do # @spec APPLE-WORKER-005
    attempt = create(:apple_verification_attempt)

    attempt.update!(status: "running", started_at: Time.current)
    attempt.source_digest = digest

    expect(attempt).not_to be_valid
    expect(attempt.errors[:base]).to include("attempt execution binding is immutable")
  end

  it "allows an attempt to bind a draft workflow during agent iteration" do # @spec APPLE-WORKER-005
    workflow = create(:apple_verification_workflow_revision)
    attempt = build(:apple_verification_attempt,
      account: workflow.account,
      project: workflow.project,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      lifecycle_gate: workflow.lifecycle_gate)

    expect(attempt).to be_valid
  end

  it "requires an attempt at an enforcement gate to bind an approved workflow" do # @spec APPLE-WORKER-005
    workflow = create(:apple_verification_workflow_revision, lifecycle_gate: "pull_request_verification")
    attempt = build(:apple_verification_attempt,
      account: workflow.account,
      project: workflow.project,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      lifecycle_gate: workflow.lifecycle_gate)

    expect(attempt).not_to be_valid
    expect(attempt.errors[:apple_verification_workflow_revision]).to include("must be approved")
  end

  it "rejects an attempt when its workflow profile has been revoked" do # @spec APPLE-WORKER-005
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    workflow = create(:apple_verification_workflow_revision,
      project:,
      account: project.account,
      lifecycle_gate: "pull_request_verification")
    workflow.approve!(actor: administrator)
    workflow.apple_worker_profile.update!(status: "revoked")
    attempt = build(:apple_verification_attempt,
      account: workflow.account,
      project: workflow.project,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      lifecycle_gate: workflow.lifecycle_gate)

    expect(attempt).not_to be_valid
    expect(attempt.errors[:apple_worker_profile]).to include("must not be revoked")
  end

  it "requires a waiver to name required checks for its workflow" do # @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    administrator = create(:user, account: attempt.account)
    administrator.add_role(:project_admin, attempt.project)
    waiver = AppleVerificationWaiver.new(
      account: attempt.account, project: attempt.project, apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: administrator, source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate, reason: "Known simulator outage", expires_at: 1.hour.from_now
    )

    expect(waiver).not_to be_valid
    expect(waiver.errors[:check_ids]).to include("must identify at least one required check")

    waiver.check_ids = [ "screenshot" ]

    expect(waiver).not_to be_valid
    expect(waiver.errors[:check_ids]).to include("must identify required checks for the workflow")
  end

  it "destroys Apple verification records with their project" do # @spec APPLE-WORKER-005 @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    administrator = create(:user, account: attempt.account)
    administrator.add_role(:project_admin, attempt.project)
    waiver = AppleVerificationWaiver.create!(
      account: attempt.account,
      project: attempt.project,
      apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: administrator,
      source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate,
      check_ids: [ "test" ],
      reason: "Known simulator outage",
      expires_at: 1.hour.from_now
    )

    expect { attempt.project.destroy! }
      .to change(AppleVerificationWaiver, :count).by(-1)
      .and change(AppleVerificationAttempt, :count).by(-1)
      .and change(AppleVerificationWorkflowRevision, :count).by(-1)
    expect { waiver.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "keeps Apple audit and VM-ledger ownership bound to the attempt" do # @spec APPLE-WORKER-007
    attempt = create(:apple_verification_attempt)
    ledger = ExecutionResourceLedgerEntry.new(
      apple_verification_attempt: attempt,
      runner_type: "apple_verification", resource_kind: "verification_vm", status: "provisioning", tags: {}, runner_handle: {}
    )
    event = ExecutionAuditEvent.new(
      apple_verification_attempt: attempt,
      event_name: "apple.verification_started", event_version: 1, credential_classes: [], network_policy: {}, metadata: {}
    )

    expect(ledger).to be_valid
    expect { ledger.save! }.to change(ExecutionResourceLedgerEntry, :count).by(1)
    expect(event).to be_valid
    expect(ledger).to have_attributes(account: attempt.account, project: attempt.project)
    expect(event).to have_attributes(account: attempt.account, project: attempt.project)
  end

  it "destroys waivers before their creators during account teardown" do # @spec APPLE-WORKER-006
    attempt = create(:apple_verification_attempt)
    administrator = create(:user, account: attempt.account)
    administrator.add_role(:project_admin, attempt.project)
    create(:apple_verification_waiver,
      account: attempt.account,
      project: attempt.project,
      apple_verification_attempt: attempt,
      apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
      created_by: administrator,
      source_digest: attempt.source_digest,
      lifecycle_gate: attempt.lifecycle_gate,
      check_ids: [ "test" ])

    expect { attempt.account.destroy! }
      .to change(AppleVerificationWaiver, :count).by(-1)
      .and change { User.where(id: administrator.id).count }.from(1).to(0)
  end

  it "destroys retry descendants before source attempts during account teardown" do # @spec APPLE-VERIFY-006
    source_attempt = create(:apple_verification_attempt, status: "failed")
    create(:apple_verification_attempt,
      account: source_attempt.account,
      project: source_attempt.project,
      apple_verification_workflow_revision: source_attempt.apple_verification_workflow_revision,
      apple_worker_profile: source_attempt.apple_worker_profile,
      source_digest: source_attempt.source_digest,
      lifecycle_gate: source_attempt.lifecycle_gate,
      retry_number: 1,
      retry_of_attempt: source_attempt)

    expect { source_attempt.account.destroy! }
      .to change(AppleVerificationAttempt, :count).by(-2)
  end

  it "refuses to delete an approver whose approval is still retained" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    revision.approve!(actor: administrator)

    expect { administrator.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    expect(revision.reload).to have_attributes(approved_by_id: administrator.id, status: "approved")
  end

  it "destroys approved workflow revisions before their approvers during account teardown" do # @spec APPLE-WORKER-004
    project = create(:project)
    administrator = create(:user, account: project.account)
    administrator.add_role(:project_admin, project)
    revision = create(:apple_verification_workflow_revision, project:, account: project.account)
    revision.approve!(actor: administrator)

    expect { project.account.destroy! }
      .to change(AppleVerificationWorkflowRevision, :count).by(-1)
      .and change { User.where(id: administrator.id).count }.from(1).to(0)
  end

  it "rejects Apple audit and VM-ledger records with another account" do # @spec APPLE-WORKER-007
    attempt = create(:apple_verification_attempt)
    other_account = create(:account)
    ledger = ExecutionResourceLedgerEntry.new(
      account: other_account, apple_verification_attempt: attempt,
      runner_type: "apple_verification", resource_kind: "verification_vm", status: "provisioning", tags: {}, runner_handle: {}
    )
    event = ExecutionAuditEvent.new(
      account: other_account, apple_verification_attempt: attempt,
      event_name: "apple.verification_started", event_version: 1, credential_classes: [], network_policy: {}, metadata: {}
    )

    expect(ledger).to be_invalid
    expect(ledger.errors[:account]).to include("must match the Apple verification attempt's account")
    expect(event).to be_invalid
    expect(event.errors[:account]).to include("must match the Apple verification attempt's account")
  end
end
