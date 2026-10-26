# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "accepts a justified single-check plan and retains declared omissions" do
    plan = described_class.call(
      selected_checks: [ { producer: "behavioral_testing", fit: "Exercises the payment boundary", required_inputs: [ "test suite" ], assumptions: [], resource_expectations: "small", residual_gaps: [ "Does not assess correspondence" ] } ],
      exclusions: [ { producer: "formal_verification", reason: "No declared model" } ]
    )

    expect(plan.selected_checks).to have_attributes(size: 1)
    expect(plan.exclusions).to eq([ { producer: "formal_verification", reason: "No declared model" } ])
  end
end
