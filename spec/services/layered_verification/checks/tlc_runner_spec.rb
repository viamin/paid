# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an absent model as non-applicable rather than a passing check" do
    result = described_class.call(command_runner: ->(*) { raise "unexpected" }, module_path: nil, config_path: nil)

    expect(result).to include(execution_state: "non_applicable", obligation_coverage: "unresolved")
  end
end
