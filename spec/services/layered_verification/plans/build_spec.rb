# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-layer plan and records its omissions" do
    plan = described_class.call(
      checks: [ { producer: "behavioral_testing", fit: "Exercises the supplied scenario", required_inputs: [ "scenario" ], assumptions: [ "test environment matches target" ], resource_expectations: { tokens: 100 }, limitations: "Does not establish semantic correspondence." } ],
      omissions: [ { producer: "formal_verification", reason: "No declared model" } ],
      residual_gaps: [ "Business interpretation remains human-reviewed." ]
    )

    expect(plan.selected_checks).to contain_exactly(have_attributes(producer: "behavioral_testing"))
    expect(plan.omissions).to eq([ { "producer" => "formal_verification", "reason" => "No declared model" } ])
    expect(plan.residual_gaps).to include("Business interpretation remains human-reviewed.")
  end
end
