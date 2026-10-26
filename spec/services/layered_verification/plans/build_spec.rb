# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "selects correspondence checks from available claims without imposing a minimum" do
    obligation = create(:layered_verification_obligation)
    create(:layered_verification_correspondence_claim, obligation:, claim_type: "business_to_spec")

    plan = described_class.call(obligations: [ obligation ], sources: [ "docs/intent/payments" ])

    expect(plan[:selected_checks]).to include("business_to_spec")
    expect(plan[:selected_checks]).not_to include("formal_verification")
    expect(plan[:omissions]).to include(a_hash_including(check: "formal_verification"))
  end

  # @spec LAYERED-VERIFY-021
  it "records a single applicable check and residual gaps" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(obligations: [ obligation ], sources: [])

    expect(plan[:selected_checks]).to eq([ "linkage_freshness" ])
    expect(plan[:residual_gaps]).not_to be_empty
  end
end
