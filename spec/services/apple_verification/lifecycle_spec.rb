# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-WORKER-003
RSpec.describe AppleVerification::Lifecycle do
  let(:agent_run) { create(:agent_run) }
  let(:host) { instance_double(AppleVerification::HostService) }

  before { FeatureFlags.enable!(:apple_verification_workers, project: agent_run.project) }
  after { ExecutionRunners.unregister_reconciliation_runner(:apple_tart) }

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

  it "reuses the persisted handle and ledger records for a duplicate request" do
    allow(host).to receive(:call).with(
      version: "v1", operation: "clone", token: "host-token", payload: hash_including("image_id" => "paid-macos")
    ).once.and_return("vm_id" => "paid-vm-1")
    allow(host).to receive(:call).with(
      version: "v1", operation: "start", token: "host-token", payload: hash_including("vm_id" => "paid-vm-1")
    ).once.and_return("vm_id" => "paid-vm-1", "connection" => { "ready" => true })

    lifecycle = described_class.new(host:, token: "host-token")
    first = lifecycle.provision(agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1")
    second = lifecycle.provision(agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1")

    expect(second).to eq(first)
    expect(ProvisioningIntent.where("metadata ->> 'request_id' = ?", "request-1")).to contain_exactly(ProvisioningIntent.last)
    expect(ExecutionResourceLedgerEntry.where(agent_run:)).to contain_exactly(ExecutionResourceLedgerEntry.last)
  end

  it "leaves a created VM reconcileable when start fails" do
    allow(host).to receive(:call).with(
      version: "v1", operation: "clone", token: "host-token", payload: hash_including("image_id" => "paid-macos")
    ).and_return("vm_id" => "paid-vm-1")
    allow(host).to receive(:call).with(
      version: "v1", operation: "start", token: "host-token", payload: hash_including("vm_id" => "paid-vm-1")
    ).and_raise(Timeout::Error)
    allow(host).to receive(:call).with(
      version: "v1", operation: "destroy", token: "host-token", payload: hash_including("vm_id" => "paid-vm-1")
    ).and_return("vm_id" => "paid-vm-1", "state" => "destroyed")
    allow(host).to receive(:call).with(
      version: "v1", operation: "inventory", token: "host-token", payload: hash_including("ownership_tags")
    ).and_return([])

    expect {
      described_class.new(host:, token: "host-token").provision(
        agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1"
      )
    }.to raise_error(Timeout::Error)

    expect(ProvisioningIntent.last).to have_attributes(status: "created", provider_resource_id: "paid-vm-1")
    expect { ExecutionRunners::ResourceReconciler.new.call }.to change(ExecutionResourceCleanup, :count).by(1)
    expect(ProvisioningIntent.last).to have_attributes(status: "failed")
  end
end
