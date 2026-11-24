# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Resume do
  def failed_audit(project:, obligation:, status: "failed")
    unless obligation.approval_state == "approved"
      obligation.record_approval!(revision: "intent-v1", approval_reference: "docs/intent/payments.md", persisted: true)
    end
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status:,
      base_commit_sha: "sha-1",
      external_metadata: { "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "sha-1", "budget" => { "max_minutes" => 5 },
        "dependencies" => { "environment" => "isolated_execution_environment" },
        "plan" => { obligation.id.to_s => { "selected_checks" => %w[formal_verification] } }
      } })
  end

  def failed_repair(audit:, result_commit_sha:)
    create(:agent_run, issue: nil, project: audit.project, goal: "layered_verification_repair", status: "failed",
      custom_prompt: "Repair the audited finding.", originating_audit_run: audit,
      external_metadata: audit.external_metadata, result_commit_sha:)
  end

  # @spec LAYERED-VERIFY-020
  it "dispatches a successor that preserves the validated metadata and resumption decision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)

    successor = described_class.call(agent_run: audit, user:)

    expect(successor).to have_attributes(project:, goal: "layered_verification_audit", status: "queued", base_commit_sha: "sha-1")
    metadata = successor.external_metadata.fetch("layered_verification")
    expect(metadata.fetch("obligation_ids")).to eq([ obligation.id ])
    expect(metadata.fetch("budget")).to eq("max_minutes" => 5)
    expect(metadata.fetch("plan")).to be_present
    expect(metadata.fetch("impact")).to eq("reused_check_result_ids" => [], "invalidated_check_result_ids" => [], "limitations" => [])
    expect(metadata.dig("resumption", "resumed_from_run_id")).to eq(audit.id)
    expect(metadata.dig("resumption", "requested_by_id")).to eq(user.id)
  end

  # @spec LAYERED-VERIFY-019 LAYERED-VERIFY-020
  it "invalidates old evidence and stamps the successor when the execution environment changes" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    fresh_dependencies = LayeredVerification::DependencySnapshot.call(project:)
    old_dependencies = fresh_dependencies.deep_dup
    old_dependencies["environment"]["digest"] = "sha256:old-runtime"
    old_dependencies["tool_versions"]["tlc_runtime_image_digest"] = "sha256:old-runtime"
    audit.external_metadata["layered_verification"]["dependencies"] = old_dependencies
    audit.save!
    result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      input_revision: { "code" => "sha-1", "external_revision" => obligation.external_revision,
        "dependencies" => old_dependencies })

    successor = described_class.call(agent_run: audit, user:)
    metadata = successor.external_metadata.fetch("layered_verification")

    expect(metadata.fetch("dependencies")).to eq(fresh_dependencies)
    expect(metadata.dig("impact", "reused_check_result_ids")).to be_empty
    expect(metadata.dig("impact", "invalidated_check_result_ids")).to eq([ result.id ])
  end

  # @spec LAYERED-VERIFY-020
  it "continues a repair as verification-only work pinned to its produced revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    prior_result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      input_revision: { "code" => "sha-1", "external_revision" => obligation.external_revision })
    repaired_revision = "b" * 40
    repair = failed_repair(audit:, result_commit_sha: repaired_revision)

    successor = described_class.call(agent_run: repair, user:)

    expect(successor).to have_attributes(
      goal: "layered_verification_audit", custom_prompt: nil, originating_audit_run: nil,
      base_commit_sha: repaired_revision)
    successor_metadata = successor.external_metadata.fetch("layered_verification")
    expect(successor_metadata.fetch("target_revision")).to eq(repaired_revision)
    expect(successor_metadata.dig("impact", "invalidated_check_result_ids")).to include(prior_result.id)
    expect(successor_metadata.fetch("resumption")).to include(
      "resumed_from_run_id" => repair.id,
      "interrupted_goal" => "layered_verification_repair",
      "originating_audit_run_id" => audit.id
    )
  end

  # @spec LAYERED-VERIFY-020
  it "rejects repair resumption when no post-mutation revision was recorded" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    repair = failed_repair(audit:, result_commit_sha: nil)

    expect { described_class.call(agent_run: repair, user:) }
      .to raise_error(ArgumentError, "a repair requires a recorded post-mutation revision before resumption")
  end

  it "refuses to admit a successor while an active audit covers the same scope and revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    failed_audit(project:, obligation:, status: "queued")

    expect { described_class.call(agent_run: audit, user:) }
      .to raise_error(LayeredVerification::Audits::Request::DuplicateAuditError)
  end
end
