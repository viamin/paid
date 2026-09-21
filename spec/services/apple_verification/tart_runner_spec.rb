# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-WORKER-010
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

  it "normalizes host inventory responses for reconciliation" do
    host = instance_double(AppleVerification::HostClient)
    runner = described_class.new(host:, token: "host-token")
    allow(host).to receive(:call).and_return([ {
      "vm_id" => "paid-vm-9",
      "tags" => { "paid.run_id" => "7", "paid.resource" => "apple_vm" },
      "state" => "running",
      "image_id" => "paid-macos"
    } ])

    resources = runner.list_resources_by_tags(tags: { "paid.run_id" => "7" })

    expect(resources).to all(be_a(ExecutionRunners::ManagedResource))
    expect(resources.first).to have_attributes(
      runner_type: :apple_tart,
      resource_kind: "apple_vm",
      identifier: "paid-vm-9",
      ownership_tags: include("paid.run_id" => "7"),
      metadata: include("state" => "running", "image_id" => "paid-macos")
    )
  end
end
