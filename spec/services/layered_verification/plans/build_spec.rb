# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified plan without a formal model or a minimum check count" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(obligation:)

    expect(plan.checks.map(&:producer)).to include("semantic_audit", "formal_verification")
    expect(plan.checks.find { |check| check.producer == "formal_verification" }.applicable).to be(false)
    expect(plan.residual_gaps).to include("No declared TLA+ module/config pair.")
  end
end
