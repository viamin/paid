# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a single-check plan and explicitly explains omitted checks" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(obligations: [ obligation ], requested_checks: [ "linkage_freshness" ])

    expect(plan.fetch("selected_checks")).to eq([ "linkage_freshness" ])
    expect(plan.fetch("exclusions").fetch("formal_verification")).to eq("no declared formal model")
  end
end
