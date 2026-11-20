# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "records an absent model as non-applicable rather than a passing check" do
    result = described_class.call(command_runner: ->(*) { raise "unexpected" }, module_path: nil, config_path: nil)

    expect(result).to include(execution_state: "non_applicable", obligation_coverage: "unresolved")
  end

  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-022
  it "stores generated TLC state outside the read-only canonical checkout" do
    commands = []
    command_runner = lambda do |*command|
      commands << command
      [ "Model checking completed.", 0 ]
    end

    result = described_class.call(command_runner:, module_path: "models/Checkout.tla", config_path: "models/Checkout.cfg")

    expect(commands).to contain_exactly(
      [ "tlc", "-metadir", a_string_matching(%r{\A/tmp/paid-layered-verification-tlc-[0-9a-f]{24}\z}),
       "-config", "models/Checkout.cfg", "models/Checkout.tla" ]
    )
    expect(result).to include(execution_state: "completed", obligation_coverage: "supported")
  end

  # @spec LAYERED-VERIFY-022
  it "isolates metadata for checks started within the same clock tick" do
    directories = []
    command_runner = lambda do |*command|
      directories << command.fetch(2)
      [ "Model checking completed.", 0 ]
    end

    2.times { described_class.call(command_runner:, module_path: "Checkout.tla", config_path: "Checkout.cfg") }

    expect(directories.uniq.size).to eq(2)
  end
end
