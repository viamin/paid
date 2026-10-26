# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single check and records omitted checks" do
    plan = described_class.call(
      scope: "PAYMENTS-001",
      selected_checks: [ "formal_verification" ],
      omissions: { "semantic_audit" => "No source passages were supplied." },
      budget: 2_000
    )

    expect(plan.fetch(:selected_checks)).to eq([ "formal_verification" ])
    expect(plan.dig(:omissions, "semantic_audit")).to be_present
    expect(plan.fetch(:budget)).to eq(2_000)
  end
end
