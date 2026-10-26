# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "builds a justified single-layer plan without requiring a model or semantic audit" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(
      obligations: [ obligation ],
      available_artifacts: { specs: true, tests: true },
      selected_checks: [ "behavioral_testing" ],
      exclusions: { "formal_verification" => "no declared model" }
    )

    expect(plan.selected_checks).to eq([ "behavioral_testing" ])
    expect(plan.exclusions).to include("formal_verification" => "no declared model")
    expect(plan.residual_gaps).to include("semantic_audit was not selected")
    expect(plan.obligation_ids).to eq([ obligation.id ])
  end
end
