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
    expect(ProvisioningIntent.last).to have_attributes(
      runner_type: "apple_tart", resource_kind: "apple_vm", request_id: "request-1", status: "linked"
    )
    expect(ProvisioningIntent.last.ownership_tags).to include("paid.request_id" => "request-1")
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
    expect(ProvisioningIntent.where(request_id: "request-1")).to contain_exactly(ProvisioningIntent.last)
    expect(ExecutionResourceLedgerEntry.where(agent_run:)).to contain_exactly(ExecutionResourceLedgerEntry.last)
  end

  it "isolates identical request IDs to their owning agent run" do
    other_run = create(:agent_run)
    FeatureFlags.enable!(:apple_verification_workers, project: other_run.project)
    allow(host).to receive(:call).with(
      version: "v1", operation: "clone", token: "host-token", payload: hash_including("image_id" => "paid-macos")
    ).and_return({ "vm_id" => "paid-vm-1" }, { "vm_id" => "paid-vm-2" })
    allow(host).to receive(:call).with(
      version: "v1", operation: "start", token: "host-token", payload: hash_including("vm_id")
    ).and_return("vm_id" => "paid-vm-1", "connection" => { "ready" => true })

    lifecycle = described_class.new(host:, token: "host-token")
    first = lifecycle.provision(agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1")
    second = lifecycle.provision(agent_run: other_run, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1")

    expect([ first.identifier, second.identifier ]).to contain_exactly("paid-vm-1", "paid-vm-2")
    expect(ProvisioningIntent.where(request_id: "request-1")).to contain_exactly(
      have_attributes(agent_run: agent_run), have_attributes(agent_run: other_run)
    )
  end

  it "leaves a created VM reconcileable when start fails" do
    configure_reconciliation_runner
    stub_failed_lifecycle_requests

    expect {
      described_class.new(host:, token: "host-token").provision(
        agent_run:, image_id: "paid-macos", profile_id: "ios-standard", request_id: "request-1"
      )
    }.to raise_error(Timeout::Error)

    expect(ProvisioningIntent.last).to have_attributes(status: "created", provider_resource_id: "paid-vm-1")
    expect { ExecutionRunners::ResourceReconciler.new.call }.to change(ExecutionResourceCleanup, :count).by(1)
    expect(ProvisioningIntent.last).to have_attributes(status: "failed")
    expect(ExecutionResourceLedgerEntry.last).to have_attributes(status: "deleted", provider_resource_id: "paid-vm-1")
  end

  it "links and deletes the pre-created ledger entry after a post-clone crash" do
    configure_reconciliation_runner
    stub_cleanup_requests
    intent, entry = create_post_clone_crash_records

    expect { ExecutionRunners::ResourceReconciler.new.call }.to change(ExecutionResourceCleanup, :count).by(1)

    expect(intent.reload).to have_attributes(status: "failed")
    expect(entry.reload).to have_attributes(status: "deleted", provider_resource_id: "paid-vm-1")
  end

  def create_post_clone_crash_records
    intent = create(:provisioning_intent,
      agent_run:,
      runner_type: "apple_tart",
      resource_kind: "apple_vm",
      request_id: "request-1",
      provider_resource_id: "paid-vm-1",
      status: "created")
    intent.update!(ownership_tags: intent.ownership_tags.merge("paid.request_id" => intent.request_id))
    entry = create(:execution_resource_ledger_entry,
      account: agent_run.project.account,
      project: agent_run.project,
      agent_run:,
      runner_type: "apple_tart",
      backend: "tart",
      resource_kind: "primary_environment",
      tags: intent.ownership_tags)
    [ intent, entry ]
  end

  def stub_failed_lifecycle_requests
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
  end

  def stub_cleanup_requests
    allow(host).to receive(:call).with(
      version: "v1", operation: "destroy", token: "host-token", payload: hash_including("vm_id" => "paid-vm-1")
    ).and_return("vm_id" => "paid-vm-1", "state" => "destroyed")
    allow(host).to receive(:call).with(
      version: "v1", operation: "inventory", token: "host-token", payload: hash_including("ownership_tags")
    ).and_return([])
  end

  def configure_reconciliation_runner
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APPLE_VERIFICATION_HOST_URL").and_return("https://macos-worker.example.test")
    allow(ENV).to receive(:[]).with("APPLE_VERIFICATION_HOST_TOKEN").and_return("host-token")
    allow(AppleVerification::HostClient).to receive(:new).with(endpoint: "https://macos-worker.example.test").and_return(host)
    AppleVerification::TartRunner.register_from_environment!
  end
end
