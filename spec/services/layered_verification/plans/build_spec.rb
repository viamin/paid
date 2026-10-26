# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and records omitted capabilities" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(
      obligation:,
      available_artifacts: [ "specification" ],
      requested_checks: [ "linkage_freshness" ]
    )

    expect(plan.selected_checks).to eq([ "linkage_freshness" ])
    expect(plan.omissions).to include("formal_verification", "semantic_audit")
  end
end
