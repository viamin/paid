# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "creates a finding for a contradiction without treating a completed run as resolution" do
    obligation = create(:layered_verification_obligation)
    result = create(:layered_verification_check_result, obligation:, execution_state: "completed", obligation_coverage: "contradicted")

    coverage = described_class.call(obligation:, check_results: [ result ])

    expect(coverage.verdict).to eq("contradicted")
    expect(coverage.finding).to be_persisted
    expect(coverage.finding).to be_open
  end
end
