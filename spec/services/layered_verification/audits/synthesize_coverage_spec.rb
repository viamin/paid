# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "records separate business-intent and verification-coverage views and creates a finding for contradiction" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")
    create(:layered_verification_check_result, obligation:, agent_run: run,
      producer: "implementation_conformance", execution_state: "completed", obligation_coverage: "contradicted",
      input_revision: { "intent" => "abc" }, limitations: "Source coverage is bounded")

    report = described_class.call(agent_run: run, obligations: [ obligation ])

    expect(report.business_intent_view).to include(obligation.external_identity)
    expect(report.verification_coverage_view.fetch(obligation.external_identity)).to eq("contradicted")
    expect(LayeredVerificationFinding.find_by(obligation:)).to be_present
  end
end
