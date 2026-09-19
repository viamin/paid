# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-WORKER-003
RSpec.describe AppleVerification::TartRunner do
  after { ExecutionRunners.unregister_reconciliation_runner(:apple_tart) }

  it "registers a configured runner that a fresh reconciliation process can resolve" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APPLE_VERIFICATION_HOST_URL").and_return("https://macos-worker.example.test")
    allow(ENV).to receive(:[]).with("APPLE_VERIFICATION_HOST_TOKEN").and_return("host-token")

    described_class.register_from_environment!

    expect(ExecutionRunners.for_type(:apple_tart)).to be_a(described_class)
  end

  it "does not register a runner without durable host configuration" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APPLE_VERIFICATION_HOST_URL").and_return(nil)

    described_class.register_from_environment!

    expect { ExecutionRunners.for_type(:apple_tart) }.to raise_error(ArgumentError, /Unknown execution runner type/)
  end
end
