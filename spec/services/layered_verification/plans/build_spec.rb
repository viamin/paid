# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and records omissions" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(
      obligations: [ obligation ],
      checks: [ { producer: "behavioral_testing", fit: "covers the bounded checkout scenario", inputs: [ "spec/requests/checkout_spec.rb" ], assumptions: [], resources: { "seconds" => 30 }, limitations: "does not cover provider outages" } ],
      exclusions: [ { producer: "formal_verification", reason: "no declared model" } ]
    )

    expect(plan.selected_checks.size).to eq(1)
    expect(plan.exclusions).to include(hash_including(producer: "formal_verification"))
  end
end
