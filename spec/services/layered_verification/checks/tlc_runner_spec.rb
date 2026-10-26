# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an absent model as non-applicable rather than a pass" do
    result = described_class.call(module_path: nil, config_path: nil)

    expect(result).to include(execution_state: "non_applicable", obligation_coverage: "unresolved")
  end

  # @spec LAYERED-VERIFY-022
  it "maps a documented tlc success command into completed evidence" do
    runner = ->(command) { expect(command).to eq("tlc -config Orders.cfg Orders.tla"); [ 0, "Model checking completed." ] }

    result = described_class.call(module_path: "Orders.tla", config_path: "Orders.cfg", command_runner: runner)

    expect(result).to include(execution_state: "completed", obligation_coverage: "supported")
  end
end
