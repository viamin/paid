# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-layer plan without treating host controls as waived" do
    plan = described_class.call(obligations: [ create(:layered_verification_obligation) ])

    expect(plan.selected_checks.map { |check| check.fetch("producer") }).to eq([ "implementation_conformance" ])
    expect(plan.assumptions.join).to include("Host CI")
    expect(plan.omissions.first.fetch("producer")).to eq("formal_verification")
  end
end
