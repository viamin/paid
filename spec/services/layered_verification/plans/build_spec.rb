# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single check and records exclusions" do
    obligation = build(:layered_verification_obligation)

    plan = described_class.call(obligations: [ obligation ], available_artifacts: { "specs" => true })

    expect(plan.selected_checks).to include("implementation_conformance")
    expect(plan.exclusions).to include("formal_verification")
    expect(plan.residual_gaps).to be_present
  end
end
