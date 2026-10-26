# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and retains explicit omissions" do
    plan = described_class.call(
      checks: [ { producer: "behavioral_testing", fit: "Exercises the declared boundary", required_inputs: [ "spec" ] } ],
      exclusions: [ { producer: "formal_verification", reason: "No declared model", limitations: "Model correspondence is unavailable" } ]
    )

    expect(plan.checks).to contain_exactly(hash_including("producer" => "behavioral_testing"))
    expect(plan.exclusions).to contain_exactly(hash_including("producer" => "formal_verification"))
  end
end
