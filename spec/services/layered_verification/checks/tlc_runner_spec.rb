# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records a missing model as non-applicable rather than a pass" do
    result = described_class.call(command_runner: ->(*) { raise "must not run" }, module_path: nil, config_path: nil)

    expect(result.execution_state).to eq("non_applicable")
    expect(result.obligation_coverage).to eq("unresolved")
    expect(result.limitations).to include("model")
  end

  # @spec LAYERED-VERIFY-022
  it "records a reported invariant violation as a contradiction" do
    result = described_class.call(
      command_runner: ->(*) { { exit_code: 1, output: "Error: Invariant safety is violated\nState 1" } },
      module_path: "Counter.tla", config_path: "Counter.cfg"
    )

    expect(result.execution_state).to eq("completed")
    expect(result.obligation_coverage).to eq("contradicted")
  end
end
