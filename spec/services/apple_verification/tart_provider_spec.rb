# frozen_string_literal: true

require "rails_helper"

module TartProviderSpecSupport
  class FakeTart
    attr_accessor :resources
    attr_reader :clones, :stopped, :destroyed, :destroys

    def initialize
      @clones = 0
      @destroys = 0
      @stopped = []
      @destroyed = []
      @resources = []
    end

    def clone(image_id:, ownership_tags:)
      @clones += 1
      { "vm_id" => "paid-vm-#{clones}", "image_id" => image_id, "ownership_tags" => ownership_tags }
    end

    def start(vm_id:, cpu_cores:, memory_mib:, disk_gb:)
      { "vm_id" => vm_id, "state" => "running", "cpu_cores" => cpu_cores, "memory_mib" => memory_mib, "disk_gb" => disk_gb }
    end

    def inspect(vm_id:) = { "vm_id" => vm_id, "state" => "running" }
    def stop(vm_id:) = stopped << vm_id
    def destroy(vm_id:) = (@destroys += 1; destroyed << vm_id)
    def inventory(ownership_tags:) = resources
    def readiness = { "cpu" => {}, "memory" => {}, "disk" => {}, "images" => [], "network" => {}, "guest_connection" => {} }
  end

  class FakeSoftnet
    attr_reader :configured
    def initialize = @configured = []
    def configure(vm_id:, network:) = configured << [ vm_id, network ]
  end
end

# @spec APPLE-WORKER-003
RSpec.describe AppleVerification::TartProvider do
  let(:tart) { TartProviderSpecSupport::FakeTart.new }
  let(:softnet) { TartProviderSpecSupport::FakeSoftnet.new }
  let(:provider) do
    described_class.new(
      tart:, softnet:,
      profiles: { "ios-standard" => { cpu_cores: 2, memory_mib: 4096, disk_gb: 40, network: "paid-egress" } }
    )
  end

  it "is idempotent for duplicate provision requests and configures Softnet behind the contract" do
    first = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags)
    second = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags)
    provider.start(request_id: "request-2", vm_id: first.fetch("vm_id"), profile_id: "ios-standard")

    expect(second).to eq(first)
    expect(tart.clones).to eq(1)
    expect(softnet.configured).to eq([ [ first.fetch("vm_id"), "paid-egress" ] ])
  end

  it "recovers stop and destroy after partial provisioning" do
    vm = provider.clone(request_id: "clone", image_id: "paid-macos", ownership_tags: tags).fetch("vm_id")

    provider.stop(request_id: "stop", vm_id: vm)
    provider.destroy(request_id: "destroy", vm_id: vm)
    provider.destroy(request_id: "destroy", vm_id: vm)

    expect(tart.stopped).to include(vm)
    expect(tart.destroyed).to include(vm)
    expect(tart.destroys).to eq(1)
  end

  it "normalizes Paid-owned inventory for reconciliation" do
    tart.resources = [ { "vm_id" => "paid-vm-9", "tags" => tags, "state" => "running" } ]

    resources = provider.inventory(ownership_tags: { "paid.run_id" => "7" })

    expect(resources.first).to be_a(ExecutionRunners::ManagedResource)
    expect(resources.first.identifier).to eq("paid-vm-9")
    expect(resources.first.ownership_tags).to include("paid.run_id" => "7")
  end

  def tags = { "paid.run_id" => "7", "paid.resource" => "apple_vm" }
end
