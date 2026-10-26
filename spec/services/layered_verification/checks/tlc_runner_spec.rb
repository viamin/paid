# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an absent model as an explicit non-applicable result" do
    result = described_class.call(obligation: create(:layered_verification_obligation), agent_run: nil, model: nil)

    expect(result).to have_attributes(execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result.limitations).to include("no declared formal model")
  end
end
