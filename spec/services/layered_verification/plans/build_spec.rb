# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and states the omitted formal check" do
    plan = described_class.call(obligations: [ build(:layered_verification_obligation) ])

    expect(plan[:checks]).to contain_exactly(include(name: "business_to_spec"))
    expect(plan[:omissions]).to contain_exactly(include(name: "formal_verification"))
    expect(plan[:host_checks]).to include("ci", "security", "approved_intent_conformance")
  end
end
