# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single check and records its omissions" do
    plan = described_class.call(
      checks: [ { "producer" => "behavioral_testing", "fit" => "covers the supplied executable scenario" } ],
      exclusions: [ { "producer" => "formal_verification", "reason" => "no declared model" } ],
      required_inputs: [ "scenario" ],
      assumptions: [ "scenario represents the bounded obligation" ],
      resource_expectations: { "max_tokens" => 500 }
    )

    expect(plan.selected_checks).to contain_exactly(include("producer" => "behavioral_testing"))
    expect(plan.exclusions).to contain_exactly(include("producer" => "formal_verification"))
    expect(plan.residual_gaps).not_to be_empty
  end

  # @spec LAYERED-VERIFY-021
  it "does not treat a verification plan as a waiver of host controls" do
    plan = described_class.call(checks: [], exclusions: [], required_inputs: [], assumptions: [], resource_expectations: {})

    expect(plan.host_controls).to include("CI", "security", "branch protection", "code review", "approved-intent conformance")
  end
end
