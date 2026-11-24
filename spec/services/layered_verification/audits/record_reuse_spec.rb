# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::RecordReuse do
  let(:dependencies) do
    { "environment" => { "immutable" => true, "digest" => "sha256:runtime" },
      "producer_versions" => { "paid" => "1.2.3" },
      "tool_versions" => { "tlc_runtime_image_digest" => "sha256:runtime" } }
  end

  def audit_with_impact(project:, obligation:, reused_ids:)
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit",
      external_metadata: { "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "code-v2",
        "input_revisions" => { obligation.id.to_s => obligation.external_revision },
        "dependencies" => dependencies,
        "impact" => { "reused_check_result_ids" => reused_ids }
      } })
  end

  def input_revision(obligation)
    { "code" => "code-v2", "external_revision" => obligation.external_revision,
      "scope_paths" => LayeredVerification::ScopeSnapshot.call(obligation).paths,
      "dependencies" => dependencies }
  end

  # @spec LAYERED-VERIFY-019
  it "carries a reusable prior result forward for this run instead of recomputing it" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:)
    prior_run = create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "completed")
    prior = create(:layered_verification_check_result, obligation:, agent_run: prior_run,
      execution_state: "completed", obligation_coverage: "supported", limitations: "bounded state space",
      input_revision: input_revision(obligation))
    audit = audit_with_impact(project:, obligation:, reused_ids: [ prior.id ])

    expect(described_class.call(obligation:, agent_run: audit, metadata: audit.external_metadata.fetch("layered_verification"))).to be(true)

    carried = obligation.check_results.where(agent_run: audit).sole
    expect(carried).to have_attributes(producer: "formal_verification", execution_state: "completed",
      obligation_coverage: "supported", evidence_ref: prior.evidence_ref)
    expect(carried.recorder_verified).to eq("reused_result_id" => prior.id)
    expect(carried.input_revision).to include("code" => "code-v2", "external_revision" => "intent-v2")
    expect(carried.limitations).to include("bounded state space", "Reuses check result ##{prior.id}")
  end

  # @spec LAYERED-VERIFY-019
  it "preserves a contradictory result's correspondence identity when carrying it forward" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    claim = create(:layered_verification_correspondence_claim, obligation:)
    prior_run = create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "completed")
    prior = create(:layered_verification_check_result, obligation:, correspondence_claim: claim, agent_run: prior_run,
      execution_state: "completed", obligation_coverage: "contradicted", cause_signature: "model-code-drift",
      limitations: "TLC checked only the declared bounds and assumptions",
      input_revision: input_revision(obligation))
    audit = audit_with_impact(project:, obligation:, reused_ids: [ prior.id ])

    described_class.call(obligation:, agent_run: audit,
      metadata: audit.external_metadata.fetch("layered_verification"))

    carried = obligation.check_results.where(agent_run: audit).sole
    expect(carried).to have_attributes(correspondence_claim: claim, obligation_coverage: "contradicted")
    expect(carried.limitations).to include("TLC checked only the declared bounds and assumptions")
  end

  # @spec LAYERED-VERIFY-019
  it "does not carry prior coverage forward when the obligation changes after admission" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    prior_run = create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "completed")
    prior = create(:layered_verification_check_result, obligation:, agent_run: prior_run,
      input_revision: input_revision(obligation))
    audit = audit_with_impact(project:, obligation:, reused_ids: [ prior.id ])
    obligation.update!(external_revision: "intent-v3")

    expect(described_class.call(obligation:, agent_run: audit,
      metadata: audit.external_metadata.fetch("layered_verification"))).to be_nil
    expect(obligation.check_results.where(agent_run: audit)).to be_empty
  end

  it "does not reuse when the admission impact marks nothing reusable" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    audit = audit_with_impact(project:, obligation:, reused_ids: [])

    expect(described_class.call(obligation:, agent_run: audit, metadata: audit.external_metadata.fetch("layered_verification"))).to be_nil
    expect(obligation.check_results.where(agent_run: audit)).to be_empty
  end

  it "does not record a second carry-forward row when the run already has one" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    create(:layered_verification_correspondence_claim, obligation:)
    prior_run = create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "completed")
    prior = create(:layered_verification_check_result, obligation:, agent_run: prior_run,
      input_revision: input_revision(obligation))
    audit = audit_with_impact(project:, obligation:, reused_ids: [ prior.id ])
    metadata = audit.external_metadata.fetch("layered_verification")
    described_class.call(obligation:, agent_run: audit, metadata:)

    expect(described_class.call(obligation:, agent_run: audit, metadata:)).to be_nil
    expect(obligation.check_results.where(agent_run: audit, producer: "formal_verification").count).to eq(1)
  end

  it "ignores reusable ids that belong to the current run rather than a prior audit" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    audit = audit_with_impact(project:, obligation:, reused_ids: [])
    own = create(:layered_verification_check_result, obligation:, agent_run: audit)
    audit.external_metadata["layered_verification"]["impact"]["reused_check_result_ids"] = [ own.id ]

    expect(described_class.call(obligation:, agent_run: audit, metadata: audit.external_metadata.fetch("layered_verification"))).to be_nil
  end
end
