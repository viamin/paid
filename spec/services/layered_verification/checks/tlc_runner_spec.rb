# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an explicit non-applicable result when no model is declared" do
    obligation = create(:layered_verification_obligation)

    result = described_class.call(obligation:, model: nil)

    expect(result).to have_attributes(producer: "formal_verification", execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result.limitations).to include("no declared TLA+ model")
  end

  # @spec LAYERED-VERIFY-022
  it "records a contradicted completed result for an invariant violation" do
    obligation = create(:layered_verification_obligation)

    result = described_class.call(
      obligation:,
      model: { module: "Orders", config: "Orders.cfg", revision: "abc123" },
      command_runner: ->(*) { { stdout: "Invariant violation\ntrace", exitstatus: 1 } }
    )

    expect(result).to have_attributes(execution_state: "completed", obligation_coverage: "contradicted")
    expect(result.evidence_summary).to include("stdout" => "Invariant violation\ntrace")
  end
end
