# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps verification coverage separate from business-intent validation and deduplicates the finding" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    claim = create(:layered_verification_correspondence_claim, obligation:, claim_type: "business_to_spec")
    result = create(:layered_verification_check_result, obligation:, correspondence_claim: claim, agent_run: audit,
      producer: "implementation_conformance", obligation_coverage: "contradicted",
      evidence_summary: { "source_passages" => [ "docs/payments.md:12" ], "observed_behavior" => "Retries occur before authorization." },
      agent_reported: { "cause_signature" => "retry-order", "decision_question" => "Which order governs?" })

    report = described_class.call(agent_run: audit, obligations: [ obligation ])
    described_class.call(agent_run: audit, obligations: [ obligation ])

    expect(report.first).to include(obligation_coverage: "contradicted", verification_coverage: [ result.id ])
    finding = LayeredVerificationFinding.find_by!(cause_signature: "retry-order")
    expect(finding.observations.pluck("check_result_id")).to eq([ result.id, result.id ])
  end
end
