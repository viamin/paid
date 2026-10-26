# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "preserves explicit uncertainty and synthesizes one view for every obligation" do
    supported = create(:layered_verification_obligation)
    unresolved = create(:layered_verification_obligation)
    create(:layered_verification_check_result, obligation: supported, obligation_coverage: "supported")
    create(:layered_verification_check_result, obligation: unresolved, obligation_coverage: "unresolved")

    views = described_class.call(obligations: [ supported, unresolved ])

    expect(views.map(&:coverage)).to contain_exactly("supported", "unresolved")
  end
end
