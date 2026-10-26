# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "derives contradicted coverage and deduplicates a repeated cause into one finding" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      obligation_coverage: "contradicted", evidence_ref: "spec:42", limitations: "bounded input")

    expect { described_class.call(agent_run: audit, obligations: [ obligation ]) }
      .to change(LayeredVerificationFinding, :count).by(1)
    expect { described_class.call(agent_run: audit, obligations: [ obligation ]) }
      .not_to change(LayeredVerificationFinding, :count)
    expect(LayeredVerificationFinding.last.observations.last.fetch("check_result_ids")).to eq([ result.id ])
  end

  # @spec LAYERED-VERIFY-017 LAYERED-VERIFY-024
  it "reopens a resolved finding when the same scoped cause recurs" do
    first_audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: first_audit.project)
    create(:layered_verification_check_result, obligation:, agent_run: first_audit,
      obligation_coverage: "contradicted", evidence_ref: "spec:42", limitations: "bounded input")
    described_class.call(agent_run: first_audit, obligations: [ obligation ])
    finding = LayeredVerificationFinding.last
    finding.update!(status: "resolved")

    next_audit = create(:agent_run, goal: "layered_verification_audit", project: first_audit.project)
    next_result = create(:layered_verification_check_result, obligation:, agent_run: next_audit,
      obligation_coverage: "contradicted", evidence_ref: "spec:42", limitations: "bounded input")

    expect { described_class.call(agent_run: next_audit, obligations: [ obligation ]) }
      .not_to change(LayeredVerificationFinding, :count)
    expect(finding.reload.status).to eq("open")
    expect(finding.observations.last.fetch("check_result_ids")).to eq([ next_result.id ])
  end
end
