# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and records omitted checks" do
    plan = described_class.call(
      scope: "payment capture",
      sources: [ "docs/payments.md" ],
      target_revision: "abc123",
      budget: 5000,
      checks: [ { producer: "behavioral_testing", fit: "Exercises the bounded capture flow", assumptions: [], limitations: [] } ],
      omissions: [ { producer: "formal_verification", reason: "No formal model is declared" } ]
    )

    expect(plan.selected_checks).to contain_exactly(a_hash_including("producer" => "behavioral_testing"))
    expect(plan.omissions).to contain_exactly(a_hash_including("producer" => "formal_verification"))
  end
end
