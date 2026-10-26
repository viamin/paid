# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "allows a justified single-layer plan and records omissions" do
    plan = described_class.call(
      selected_checks: [ { producer: "behavioral_testing", fit: "Examples cover this bounded obligation" } ],
      omissions: [ { producer: "formal_verification", reason: "No declared model" } ],
      residual_gaps: [ "Semantic correspondence remains uncertain" ]
    )

    expect(plan.selected_checks).to have_attributes(size: 1)
    expect(plan.omissions).to eq([ { "producer" => "formal_verification", "reason" => "No declared model" } ])
  end
end
