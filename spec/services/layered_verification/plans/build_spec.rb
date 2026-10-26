# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "accepts a justified single check and preserves explained omissions" do
    plan = described_class.call(
      selected_checks: [ { producer: "behavioral_testing", fit: "examples exist", required_inputs: [ "test command" ], assumptions: [], resource_expectations: "bounded", residual_gaps: "no model declared" } ],
      omissions: [ { producer: "formal_verification", reason: "no declared model" } ]
    )

    expect(plan).to include("selected_checks" => [ include("producer" => "behavioral_testing") ])
    expect(plan.fetch("omissions")).to include(include("producer" => "formal_verification"))
  end
end
