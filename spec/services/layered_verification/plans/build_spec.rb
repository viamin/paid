# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and keeps host checks outside its authority" do
    plan = described_class.call(
      checks: [ { producer: "formal_verification", fit: "The declared model covers the scoped state machine", required_inputs: [ "orders.tla", "orders.cfg" ], assumptions: [ "bounded model" ], resource_expectations: { "seconds" => 60 }, limitations: "Model bounds do not prove production scale." } ],
      exclusions: [ { producer: "mutation_testing", reason: "No supported mutation command is declared." } ],
      residual_gaps: [ "No independent semantic audit was selected." ]
    )

    expect(plan.checks).to have_attributes(size: 1)
    expect(plan.exclusions.first).to include("producer" => "mutation_testing")
    expect(plan.host_checks).to include("CI", "security", "branch protection", "code review", "approved-intent conformance")
  end
end
