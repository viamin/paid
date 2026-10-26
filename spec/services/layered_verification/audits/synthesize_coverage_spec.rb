# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps an obligation unresolved when its selected check could not run" do
    obligation = create(:layered_verification_obligation)
    create(:layered_verification_check_result, obligation:, execution_state: "not_run", obligation_coverage: "unresolved")

    coverage = described_class.call(obligation:)

    expect(coverage.verdict).to eq("unresolved")
    expect(coverage.results).to all(be_a(LayeredVerificationCheckResult))
  end

  # @spec LAYERED-VERIFY-024
  it "reports a contradiction even when another check supports the obligation" do
    obligation = create(:layered_verification_obligation)
    create(:layered_verification_check_result, obligation:, obligation_coverage: "supported")
    create(:layered_verification_check_result, obligation:, obligation_coverage: "contradicted")

    expect(described_class.call(obligation:).verdict).to eq("contradicted")
  end
end
