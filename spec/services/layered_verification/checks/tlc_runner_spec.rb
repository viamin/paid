# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  let(:obligation) { create(:layered_verification_obligation) }

  # @spec LAYERED-VERIFY-022
  it "records a missing model as explicit non-applicability" do
    result = described_class.call(obligation:, module_path: nil, config_path: nil)

    expect(result).to have_attributes(producer: "formal_verification", execution_state: "non_applicable")
    expect(result.limitations).to include("No TLA+ model")
  end
end
