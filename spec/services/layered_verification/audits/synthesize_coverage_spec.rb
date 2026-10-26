# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps a contradicted obligation unresolved while recording a report and finding" do
    run = create(:agent_run, issue: nil, goal: "layered_verification_audit", custom_prompt: "audit")
    obligation = create(:layered_verification_obligation, project: run.project)
    create(:layered_verification_check_result, obligation:, agent_run: run, obligation_coverage: "contradicted")

    report = described_class.call(agent_run: run, obligations: [ obligation ])

    expect(report.verification_coverage.fetch(obligation.id.to_s)).to eq("contradicted")
    expect(LayeredVerificationFinding.find_by(obligation:)).to be_present
  end
end
