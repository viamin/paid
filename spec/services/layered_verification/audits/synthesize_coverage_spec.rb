# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  it "keeps a contradicted obligation contradicted even when another check supports it" do
    obligation = create(:layered_verification_obligation)
    create(:layered_verification_check_result, obligation:, obligation_coverage: "supported")
    create(:layered_verification_check_result, obligation:, obligation_coverage: "contradicted")

    expect(described_class.call(obligations: [ obligation ])).to eq(obligation => "contradicted")
  end
end
