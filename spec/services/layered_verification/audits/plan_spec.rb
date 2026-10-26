# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Plan do
  it "selects correspondence checks only when formal correspondence is declared" do
    obligation = create(:layered_verification_obligation)

    plan = described_class.call(obligation:)

    expect(plan[:selected].pluck(:producer)).not_to include("formal_verification")
    expect(plan[:omitted].find { |item| item[:producer] == "formal_verification" }[:rationale]).to include("Not selected")
  end
end
