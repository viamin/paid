# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::RecordFinding do
  # @spec LAYERED-VERIFY-017
  it "attaches repeated scoped observations to the unresolved finding" do
    result = create(:layered_verification_check_result, obligation_coverage: "contradicted")
    later_result = create(:layered_verification_check_result, obligation: result.obligation, obligation_coverage: "contradicted")

    finding = described_class.call(check_result: result, cause_signature: "missing-idempotency")
    repeated = described_class.call(check_result: later_result, cause_signature: "missing-idempotency")

    expect(repeated).to eq(finding)
    expect(finding.observations.pluck(:check_result_id)).to contain_exactly(result.id, later_result.id)
  end
end
