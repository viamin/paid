# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Checks::TlcRunner do
  # @spec LAYERED-VERIFY-022
  it "reports an undeclared model as explicitly non-applicable" do
    result = described_class.call(command_runner: ->(*) { raise "must not run" })

    expect(result).to include(execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(result.fetch(:limitations)).to include("No TLA+")
  end
end
