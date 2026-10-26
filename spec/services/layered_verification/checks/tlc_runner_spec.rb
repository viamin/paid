# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records a missing model as non-applicable rather than a pass" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")

    result = described_class.call(obligation:, agent_run: run, model: nil)

    expect(result).to have_attributes(execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result.limitations).to include("No TLA+")
  end
end
