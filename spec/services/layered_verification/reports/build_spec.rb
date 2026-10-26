# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Reports::Build do
  # @spec LAYERED-VERIFY-024
  it "keeps business-intent validation separate from verification coverage" do
    obligation = create(:layered_verification_obligation, approval_state: "unresolved")
    create(:layered_verification_check_result, obligation:, obligation_coverage: "unresolved")

    report = described_class.call(obligations: [ obligation ], plan: { checks: [] })

    expect(report[:business_intent_validation]).to contain_exactly(include(external_identity: obligation.external_identity))
    expect(report[:verification_coverage]).to contain_exactly(include(obligation_id: obligation.id, verdict: "unresolved"))
  end
end
