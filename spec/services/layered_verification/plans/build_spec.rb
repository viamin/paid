# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single check and preserves omissions and host gates" do
    plan = described_class.call(
      checks: [ { producer: "behavioral_testing", fit: "boundary rule", limitations: "does not assess implementation correspondence" } ],
      omissions: [ { producer: "formal_verification", reason: "no declared model" } ],
      assumptions: [ "scenario source is current" ], residual_gaps: [ "human handoff evidence unavailable" ]
    )

    expect(plan[:checks]).to contain_exactly(include(producer: "behavioral_testing"))
    expect(plan[:omissions]).to contain_exactly(include(producer: "formal_verification"))
    expect(plan[:host_gates]).to include("CI", "security", "branch protection", "code review", "approved-intent conformance")
  end
end
