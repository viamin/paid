# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  let(:obligation) { create(:layered_verification_obligation) }

  # @spec LAYERED-VERIFY-024
  it "keeps an unresolved obligation explicit rather than reporting support" do
    create(:layered_verification_check_result, obligation:, obligation_coverage: "unresolved")

    expect(described_class.call(obligation:).coverage).to eq("unresolved")
  end
end
