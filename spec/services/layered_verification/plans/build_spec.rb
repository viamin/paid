# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-layer plan and reports omitted capabilities" do
    plan = described_class.call(obligations: [ build(:layered_verification_obligation) ])

    expect(plan[:selected_checks]).to contain_exactly(include(producer: "implementation_conformance"))
    expect(plan[:exclusions]).to include(include(producer: "formal_verification"))
    expect(plan[:host_checks]).to include("ci", "security", "branch_protection", "code_review", "approved_intent_conformance")
  end
end
