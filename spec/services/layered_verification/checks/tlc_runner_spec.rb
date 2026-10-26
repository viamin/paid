# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an absent model as non-applicable rather than a pass" do
    result = described_class.call(executor: ->(*) { raise "not called" })

    expect(result).to include(execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result[:limitations]).to include("No declared")
  end

  # @spec LAYERED-VERIFY-022
  it "recognizes TLC completion" do
    result = described_class.call(executor: ->(*) { [ "Model checking completed.", true ] }, module_path: "Counter.tla", config_path: "Counter.cfg")

    expect(result).to include(execution_state: "completed", obligation_coverage: "supported")
  end
end
