# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "preserves a contradiction as a finding while completing the audit coverage view" do
    obligation = create(:layered_verification_obligation)
    claim = create(:layered_verification_correspondence_claim, obligation:)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")
    create(:layered_verification_check_result, obligation:, correspondence_claim: claim, agent_run: run,
      obligation_coverage: "contradicted")

    coverage = described_class.call(agent_run: run, obligations: [ obligation ])

    expect(coverage).to eq(obligation => "contradicted")
    expect(obligation.findings).to exist
  end
end
