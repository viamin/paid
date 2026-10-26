# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an invariant violation as a contradiction rather than an execution failure" do
    result = described_class.call(module_path: "Order.tla", config_path: "Order.cfg",
      command_runner: ->(_command) { [ "Error: Invariant invariantSafety is violated", false ] })

    expect(result.execution_state).to eq("completed")
    expect(result.obligation_coverage).to eq("contradicted")
  end

  # @spec LAYERED-VERIFY-022
  it "records an absent model as non-applicable with a limitation" do
    result = described_class.call(module_path: nil, config_path: nil, command_runner: -> { raise "not called" })

    expect(result.execution_state).to eq("non_applicable")
    expect(result.limitations).to include("No declared")
  end
end
