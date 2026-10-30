# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps mixed supported and unresolved selected results unresolved" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    create(:layered_verification_check_result, obligation:, agent_run: audit,
      obligation_coverage: "supported", limitations: "bounded input")
    create(:layered_verification_check_result, obligation:, agent_run: audit,
      execution_state: "not_run", obligation_coverage: "unresolved", limitations: "tool unavailable")

    coverage = described_class.call(agent_run: audit, obligations: [ obligation ])

    expect(coverage.dig(obligation, :obligation_coverage)).to eq("unresolved")
    # @spec LAYERED-VERIFY-015: a clean or unresolved-only audit creates no Inbox finding.
    expect(LayeredVerificationFinding.count).to eq(0)
  end

  # @spec LAYERED-VERIFY-024
  it "derives contradicted coverage and deduplicates a repeated cause into one finding" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      evidence_ref: "spec:42", limitations: "bounded input")

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
      obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      evidence_ref: "run-1/spec:42", limitations: "bounded input")
    described_class.call(agent_run: first_audit, obligations: [ obligation ])
    finding = LayeredVerificationFinding.last
    finding.update!(status: "resolved")

    next_audit = create(:agent_run, goal: "layered_verification_audit", project: first_audit.project)
    next_result = create(:layered_verification_check_result, obligation:, agent_run: next_audit,
      obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      evidence_ref: "run-2/spec:99", limitations: "bounded input")

    expect { described_class.call(agent_run: next_audit, obligations: [ obligation ]) }
      .not_to change(LayeredVerificationFinding, :count)
    expect(finding.reload.status).to eq("open")
    expect(finding.agent_run).to eq(next_audit)
    expect(finding.observations.last.fetch("check_result_ids")).to eq([ next_result.id ])
    expect(finding.source_passages).to eq([ next_result.evidence_summary ])
    expect(finding.observed_behavior).to eq("check_results" => [ next_result.id ])
    expect(finding.check_limitations).to eq([ next_result.limitations ])
  end

  # @spec LAYERED-VERIFY-017
  it "deduplicates by external identity after an obligation row is replaced" do
    first_audit = create(:agent_run, goal: "layered_verification_audit")
    original = create(:layered_verification_obligation, project: first_audit.project)
    create(:layered_verification_check_result, obligation: original, agent_run: first_audit,
      obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      limitations: "bounded input")
    described_class.call(agent_run: first_audit, obligations: [ original ])

    replacement = create(:layered_verification_obligation, project: first_audit.project,
      framework: "okf", external_identity: original.external_identity)
    next_audit = create(:agent_run, goal: "layered_verification_audit", project: first_audit.project)
    create(:layered_verification_check_result, obligation: replacement, agent_run: next_audit,
      obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      limitations: "bounded input")

    expect { described_class.call(agent_run: next_audit, obligations: [ replacement ]) }
      .not_to change(LayeredVerificationFinding, :count)
    expect(LayeredVerificationFinding.last.obligation).to eq(replacement)
  end

  # @spec LAYERED-VERIFY-017 LAYERED-VERIFY-024
  it "keeps distinct claim conflicts separate within one obligation" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    business_claim = create(:layered_verification_correspondence_claim, obligation:, claim_type: "business_to_model")
    code_claim = create(:layered_verification_correspondence_claim, obligation:, claim_type: "model_to_code")
    [ business_claim, code_claim ].each do |claim|
      create(:layered_verification_check_result, obligation:, correspondence_claim: claim, agent_run: audit,
        obligation_coverage: "contradicted", cause_signature: "incorrect-retry-order", limitations: "bounded input")
    end

    expect { described_class.call(agent_run: audit, obligations: [ obligation ]) }
      .to change(LayeredVerificationFinding, :count).by(2)
    expect(LayeredVerificationFinding.order(:correspondence_claim_type).pluck(:correspondence_claim_type))
      .to eq(%w[business_to_model model_to_code])
  end
end
