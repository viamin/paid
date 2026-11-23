# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Resume do
  def failed_audit(project:, obligation:, status: "failed")
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status:,
      base_commit_sha: "sha-1",
      external_metadata: { "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "sha-1", "budget" => { "max_minutes" => 5 },
        "dependencies" => { "environment" => "isolated_execution_environment" },
        "plan" => { obligation.id.to_s => { "selected_checks" => %w[formal_verification] } }
      } })
  end

  def decision(reusable: [], invalidated: [], limitations: [], remaining_budget: { "max_minutes" => 3 })
    LayeredVerification::Resumption::Decision.new(true, reusable, invalidated, limitations, remaining_budget)
  end

  # @spec LAYERED-VERIFY-020
  it "dispatches a successor that preserves the validated metadata and resumption decision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)

    successor = described_class.call(agent_run: audit, user:, decision: decision(reusable: [ 7 ], invalidated: [ 9 ]))

    expect(successor).to have_attributes(project:, goal: "layered_verification_audit", status: "queued", base_commit_sha: "sha-1")
    metadata = successor.external_metadata.fetch("layered_verification")
    expect(metadata.fetch("obligation_ids")).to eq([ obligation.id ])
    expect(metadata.fetch("budget")).to eq("max_minutes" => 3)
    expect(metadata.fetch("plan")).to be_present
    expect(metadata.fetch("impact")).to eq("reused_check_result_ids" => [ 7 ], "invalidated_check_result_ids" => [ 9 ], "limitations" => [])
    expect(metadata.dig("resumption", "resumed_from_run_id")).to eq(audit.id)
    expect(metadata.dig("resumption", "requested_by_id")).to eq(user.id)
  end

  # @spec LAYERED-VERIFY-020
  it "continues a repair as verification-only work without replaying its mutation prompt" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    repair = create(:agent_run, issue: nil, project:, goal: "layered_verification_repair", status: "failed",
      custom_prompt: "Repair the audited finding.", originating_audit_run: audit, external_metadata: audit.external_metadata)

    successor = described_class.call(agent_run: repair, user:, decision: decision)

    expect(successor).to have_attributes(
      goal: "layered_verification_audit", custom_prompt: nil, originating_audit_run: nil
    )
    expect(successor.external_metadata.dig("layered_verification", "resumption")).to include(
      "resumed_from_run_id" => repair.id,
      "interrupted_goal" => "layered_verification_repair",
      "originating_audit_run_id" => audit.id
    )
  end

  it "refuses to admit a successor while an active audit covers the same scope and revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    audit = failed_audit(project:, obligation:)
    failed_audit(project:, obligation:, status: "queued")

    expect { described_class.call(agent_run: audit, user:, decision: decision) }
      .to raise_error(LayeredVerification::Audits::Request::DuplicateAuditError)
  end
end
