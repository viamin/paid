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
      obligation.id.to_s => { selected_checks: [ "spec_to_code" ], fit: "mapped specification",
        exclusions: [ "no formal model" ] }
    ).permit(obligation.id.to_s => [ :fit, { selected_checks: [], exclusions: [] } ])

    plan = described_class.call(obligations: [ obligation ], selections:).fetch(obligation.id.to_s)

    expect(plan).to include("selected_checks" => [ "spec_to_code" ], "fit" => "mapped specification")
  end

  # @spec LAYERED-VERIFY-021
  it "rejects an obligation without a selected check" do
    obligation = create(:layered_verification_obligation)

    expect {
      described_class.call(obligations: [ obligation ], selections: {})
    }.to raise_error(
      LayeredVerification::Plans::Build::EmptySelectionError,
      "select at least one verification check for every obligation"
    )
  end

  # @spec LAYERED-VERIFY-021
  it "rejects a selected check without a stated fit" do
    obligation = create(:layered_verification_obligation)

    expect {
      described_class.call(obligations: [ obligation ], selections: {
        obligation.id => { selected_checks: [ "formal_verification" ], exclusions: [ "No semantic review needed" ] }
      })
    }.to raise_error(ArgumentError, /state why the selected checks fit/)
  end

  # @spec LAYERED-VERIFY-021
  it "rejects unexplained omissions from a single-check plan" do
    obligation = create(:layered_verification_obligation)

    expect {
      described_class.call(obligations: [ obligation ], selections: {
        obligation.id => { selected_checks: [ "formal_verification" ], fit: "TLA+ model is available" }
      })
    }.to raise_error(ArgumentError, /explain omitted checks/)
  end
end
