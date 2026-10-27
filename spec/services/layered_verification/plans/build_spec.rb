# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Plans::Build do
  # @spec LAYERED-VERIFY-021
  it "permits a justified single-check plan and records omissions" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(obligations: [ obligation ], selections: {
      obligation.id => { selected_checks: [ "spec_to_code" ], fit: "mapped specification", exclusions: [ "no formal model" ] }
    }).fetch(obligation.id.to_s)

    expect(plan).to include("selected_checks" => [ "spec_to_code" ], "exclusions" => [ "no formal model" ])
  end

  # @spec LAYERED-VERIFY-021
  it "normalizes controller parameters at the input boundary" do
    obligation = create(:layered_verification_obligation)
    selections = ActionController::Parameters.new(
      obligation.id.to_s => { selected_checks: [ "spec_to_code" ], fit: "mapped specification" }
    )

    plan = described_class.call(obligations: [ obligation ], selections:).fetch(obligation.id.to_s)

    expect(plan).to include("selected_checks" => [ "spec_to_code" ], "fit" => "mapped specification")
  end
end
