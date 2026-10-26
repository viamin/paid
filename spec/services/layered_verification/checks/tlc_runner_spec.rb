# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records a declared-model omission rather than treating it as a pass" do
    result = described_class.call(module_path: nil, config_path: nil, tlc_available: false, exit_status: nil, output: "")

    expect(result).to have_attributes(execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result.limitations).to include("No TLA+ model")
  end

  # @spec LAYERED-VERIFY-022
  it "recognizes a completed TLC command" do
    result = described_class.call(module_path: "Order.tla", config_path: "Order.cfg", tlc_available: true, exit_status: 0, output: "Model checking completed.")

    expect(result).to have_attributes(execution_state: "completed", obligation_coverage: "supported")
    expect(result.command).to eq("tlc -config Order.cfg Order.tla")
  end
end
