# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records a counterexample as a completed contradictory result" do
    result = described_class.call(
      module_path: "Orders.tla", config_path: "Orders.cfg",
      command_runner: ->(_command) { { exit_status: 1, output: "Error: Invariant Safety is violated" } }
    )

    expect(result.execution_state).to eq("completed")
    expect(result.obligation_coverage).to eq("contradicted")
    expect(result.limitations).to be_present
  end
end
