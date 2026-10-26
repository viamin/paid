# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024 @spec LAYERED-VERIFY-017
  it "creates one deduplicated unresolved finding while preserving each new observation" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")
    result = create(:layered_verification_check_result, obligation:, agent_run: run, obligation_coverage: "contradicted")

    first = described_class.call(agent_run: run, obligations: [ obligation ])
    second = described_class.call(agent_run: run, obligations: [ obligation ])

    expect(first.fetch(:findings).first).to eq(second.fetch(:findings).first)
    expect(first.fetch(:coverage)).to eq(obligation.id => "contradicted")
    expect(first.fetch(:findings).first.observations.count).to eq(2)
    expect(result).to be_persisted
  end
end
