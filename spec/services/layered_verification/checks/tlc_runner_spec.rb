# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records a missing model as non-applicable rather than a pass" do
    result = described_class.call(model_path: nil, config_path: nil, command_runner: ->(*) { raise "not called" })

    expect(result.execution_state).to eq("non_applicable")
    expect(result.obligation_coverage).to eq("unresolved")
  end

  # @spec LAYERED-VERIFY-022
  it "records an invariant violation as a contradiction" do
    runner = ->(command:) { { stdout: "Error: Invariant Safe is violated", stderr: "", evidence_ref: "artifact://tlc" } }

    result = described_class.call(model_path: "Spec.tla", config_path: "Spec.cfg", command_runner: runner)

    expect(result.execution_state).to eq("completed")
    expect(result.obligation_coverage).to eq("contradicted")
    expect(result.evidence_ref).to eq("artifact://tlc")
  end
end
