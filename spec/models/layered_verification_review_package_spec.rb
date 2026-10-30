# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationReviewPackage do
  # @spec LAYERED-VERIFY-023
  it "binds audit evidence to one reproducible package identity" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project,
      external_identity: "PAYMENTS-017", external_revision: "intent@1")
    obligation.record_approval!(revision: "intent@1", approval_reference: "merge#41", persisted: true)
    result = create(:layered_verification_check_result, obligation:, agent_run: audit)
    audit.update!(external_metadata: { "layered_verification" => {
      "target_revision" => "code@1", "obligation_ids" => [ obligation.id ],
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "spec_to_code" ] } }
    } })

    package = described_class.bind!(agent_run: audit)

    expect(package).to have_attributes(project: audit.project, agent_run: audit, revision: 1)
    expect(package.package_digest).to be_present
    expect(package.bound_inputs).to include(
      "obligations" => [ hash_including("external_identity" => "PAYMENTS-017", "external_revision" => "intent@1") ],
      "plan_revision" => be_present, "check_result_ids" => [ result.id ]
    )
    expect(package.bound_inputs.dig("scope", "target_revision")).to eq("code@1")
    expect(package.approvals).to eq([])
    expect(package.inbox_decisions).to eq([])
  end

  # @spec LAYERED-VERIFY-023
  it "returns the existing package while no bound input changes" do
    audit = bound_audit
    package = described_class.bind!(agent_run: audit)

    expect { described_class.bind!(agent_run: audit) }.not_to change(described_class, :count)
    expect(described_class.bind!(agent_run: audit).package_digest).to eq(package.package_digest)
  end

  # @spec LAYERED-VERIFY-023
  it "binds Inbox decisions recorded on in-scope findings while the package is open" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    create(:layered_verification_check_result, obligation:, agent_run: audit)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "plan" => { obligation.id.to_s => { "selected_checks" => [ "spec_to_code" ] } }
    } })
    finding = create(:layered_verification_finding, project: audit.project, obligation:, agent_run: audit,
      correspondence_claim_type: "spec_to_code", cause_signature: "missing-idempotency-guard")
    finding.update!(decision: { "selected_action" => "defer", "reason" => "Awaiting the business owner." })

    package = described_class.bind!(agent_run: audit)

    expect(package.inbox_decisions).to contain_exactly(hash_including("selected_action" => "defer"))
  end

  # @spec LAYERED-VERIFY-023
  it "creates a new package revision when a bound input changes and retains the prior record" do
    audit, obligation = bound_audit_with_obligation(external_revision: "intent@1")
    original = described_class.bind!(agent_run: audit)

    obligation.update!(external_revision: "intent@2")
    refreshed = described_class.bind!(agent_run: audit)

    expect(refreshed).not_to eq(original)
    expect(refreshed.revision).to eq(2)
    expect(original.reload).to be_persisted
    expect(original.revision).to eq(1)
    expect(original.bound_inputs["obligations"].first["external_revision"]).to eq("intent@1")
    expect(refreshed.bound_inputs["obligations"].first["external_revision"]).to eq("intent@2")
  end

  # @spec LAYERED-VERIFY-023 LAYERED-VERIFY-010
  it "records approval without authorizing a repair or a release" do
    user = create(:user, :owner)
    audit, = bound_audit_with_obligation
    package = described_class.bind!(agent_run: audit)

    expect { package.approve!(user:) }.not_to change { AgentRun.where(goal: "layered_verification_repair").count }
    expect(package.reload.approvals).to contain_exactly(hash_including(
      "user_id" => user.id, "package_revision" => 1, "package_digest" => package.package_digest
    ))
    expect(package.reload.revision).to eq(1)
    expect(package.reload.bound_inputs["check_result_ids"]).to eq(
      LayeredVerificationCheckResult.where(agent_run: audit).ids
    )
  end

  def bound_audit
    bound_audit_with_obligation.first
  end

  def bound_audit_with_obligation(external_revision: "intent@1")
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project, external_revision:)
    create(:layered_verification_check_result, obligation:, agent_run: audit)
    audit.update!(external_metadata: { "layered_verification" => {
      "target_revision" => "code@1", "obligation_ids" => [ obligation.id ],
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "spec_to_code" ] } }
    } })
    [ audit, obligation ]
  end
end
