# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps business-intent validation separate from verification coverage" do
    run = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: run.project)
    create(:layered_verification_check_result, obligation:, agent_run: run, producer: "semantic_audit", obligation_coverage: "contradicted")
    create(:layered_verification_check_result, obligation:, agent_run: run, producer: "behavioral_testing", obligation_coverage: "supported")

    report = described_class.call(agent_run: run, obligations: [ obligation ]).fetch(obligation)

    expect(report[:business_intent][:verdict]).to eq("contradicted")
    expect(report[:verification_coverage][:verdict]).to eq("supported")
  end
end
