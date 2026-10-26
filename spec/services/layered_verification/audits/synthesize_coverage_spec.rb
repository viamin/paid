# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do # @spec LAYERED-VERIFY-024
  let(:obligation) do
    LayeredVerificationObligation.create!(
      project: create(:project), framework: "lid", external_identity: "PAYMENT-002",
      external_revision: "abc123", scope_description: "Reject duplicate payments", approval_state: "unresolved"
    )
  end

  it "reports uncertainty rather than treating a clean execution state as support" do
    result = LayeredVerificationCheckResult.create!(
      obligation:, producer: "behavioral_testing", execution_state: "completed", obligation_coverage: "unresolved",
      input_revision: { "sha" => "abc123" }, limitations: "The boundary case has no assertion."
    )

    report = described_class.call(obligations: [ obligation ], check_results: [ result ])

    expect(report).to eq(obligation.id => { "obligation_coverage" => "unresolved", "check_result_ids" => [ result.id ] })
  end
end
