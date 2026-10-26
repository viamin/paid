# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps a contradiction visible even when another check supports the obligation" do
    run = create(:agent_run, goal: "layered_verification_audit", issue: nil,
      external_metadata: { "layered_verification_audit" => { "obligation_ids" => [ 1 ] } })
    obligation = create(:layered_verification_obligation, project: run.project)
    create(:layered_verification_check_result, obligation:, agent_run: run, obligation_coverage: "supported")
    create(:layered_verification_check_result, obligation:, agent_run: run, obligation_coverage: "contradicted")

    expect(described_class.call(agent_run: run, obligation:).coverage).to eq("contradicted")
  end
end
