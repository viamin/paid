# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-WORKER-003
RSpec.describe AppleVerification::Lifecycle do
  let(:agent_run) { create(:agent_run) }
  let(:host) { instance_double(AppleVerification::HostService) }

  before { FeatureFlags.enable!(:apple_verification_workers, project: agent_run.project) }

  it "records intent and an external ledger entry around the opaque VM handle" do
    allow(host).to receive(:call).with(
      version: "v1", operation: "clone", token: "host-token", payload: hash_including("image_id" => "paid-macos")
    ).and_return("vm_id" => "paid-vm-1")
    allow(host).to receive(:call).with(
      version: "v1", operation: "start", token: "host-token", payload: hash_including("vm_id" => "paid-vm-1")
    ).and_return("vm_id" => "paid-vm-1", "connection" => { "ready" => true })

    handle = described_class.new(host:, token: "host-token").provision(
      agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1"
    )

    expect(handle).to be_a(ExecutionRunners::RunnerHandle)
    expect(ProvisioningIntent.last).to have_attributes(runner_type: "apple_tart", resource_kind: "apple_vm", status: "linked")
    expect(ExecutionResourceLedgerEntry.last).to have_attributes(backend: "tart", status: "active", provider_resource_id: "paid-vm-1")
  end
end
