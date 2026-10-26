# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and records the omitted capabilities" do
    plan = described_class.call(
      checks: [ { producer: "behavioral_testing", fit: "existing focused suite", required_inputs: [ "spec" ], assumptions: [], resource_expectations: {}, residual_gaps: [] } ],
      omissions: [ { producer: "formal_verification", reason: "no declared model" } ]
    )

    expect(plan.checks.map { |check| check.fetch(:producer) }).to eq([ "behavioral_testing" ])
    expect(plan.omissions).to include(include(producer: "formal_verification", reason: "no declared model"))
  end
end
