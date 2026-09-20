# frozen_string_literal: true

require "rails_helper"

module TartProviderSpecSupport
  class FakeTart
    attr_accessor :resources
    attr_reader :clones, :starts, :stopped, :destroyed, :destroys

    def initialize
      @clones = 0
      @starts = []
      @destroys = 0
      @stopped = []
      @destroyed = []
      @resources = []
    end

    def clone(image_id:, ownership_tags:)
      @clones += 1
      resource = { "vm_id" => "paid-vm-#{clones}", "image_id" => image_id, "tags" => ownership_tags, "state" => "stopped" }
      resources << resource
      resource
    end

    def start(vm_id:, cpu_cores:, memory_mib:, disk_gb:)
      starts << vm_id
      resources.find { |resource| resource.fetch("vm_id") == vm_id }&.store("state", "running")
      { "vm_id" => vm_id, "state" => "running", "cpu_cores" => cpu_cores, "memory_mib" => memory_mib, "disk_gb" => disk_gb }
    end

    def inspect(vm_id:) = resources.find { |resource| resource.fetch("vm_id") == vm_id }.slice("vm_id", "state")
    def stop(vm_id:) = stopped << vm_id
    def destroy(vm_id:)
      resources.delete_at(resources.index { |resource| resource.fetch("vm_id") == vm_id } || raise(ArgumentError, "VM not found: #{vm_id}"))
      @destroys += 1
      destroyed << vm_id
    end
    def inventory(ownership_tags:)
      resources.select { |resource| matching_tags?(resource, ownership_tags) }
    end

    def matching_tags?(resource, ownership_tags)
      ownership_tags.all? { |key, value| resource.fetch("tags").fetch(key, nil) == value }
    end
    def readiness = { "cpu" => {}, "memory" => {}, "disk" => {}, "images" => [], "network" => {}, "guest_connection" => {} }
  end

  class FakeSoftnet
    attr_reader :configured
    def initialize = @configured = []
    def configure(vm_id:, network:) = configured << [ vm_id, network ]
  end
end

# @spec APPLE-WORKER-010
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

  it "rediscovers a clone by request ID after a host restart" do
    first = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags)
    restarted_provider = described_class.new(
      tart:, softnet:,
      profiles: { "ios-standard" => { cpu_cores: 2, memory_mib: 4096, disk_gb: 40, network: "paid-egress" } }
    )

    second = restarted_provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags)

    expect(second).to eq(first)
    expect(tart.clones).to eq(1)
    expect(first.fetch("tags")).to include("paid.request_id" => "request-1")
  end

  it "rediscovers an already-running VM after a host restart" do
    vm_id = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags).fetch("vm_id")
    provider.start(request_id: "request-2", vm_id:, profile_id: "ios-standard")
    restarted_softnet = TartProviderSpecSupport::FakeSoftnet.new
    restarted_provider = described_class.new(
      tart:, softnet: restarted_softnet,
      profiles: { "ios-standard" => { cpu_cores: 2, memory_mib: 4096, disk_gb: 40, network: "paid-egress" } }
    )

    response = restarted_provider.start(request_id: "request-2", vm_id:, profile_id: "ios-standard")

    expect(response).to eq("vm_id" => vm_id, "state" => "running")
    expect(tart.starts).to eq([ vm_id ])
    expect(restarted_softnet.configured).to be_empty
  end

  it "isolates identical request IDs by owning run before and after a host restart" do
    first = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags)
    second = provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags("8"))
    provider.start(request_id: "request-1:start", vm_id: first.fetch("vm_id"), profile_id: "ios-standard")
    provider.start(request_id: "request-1:start", vm_id: second.fetch("vm_id"), profile_id: "ios-standard")
    restarted_provider = described_class.new(
      tart:, softnet:,
      profiles: { "ios-standard" => { cpu_cores: 2, memory_mib: 4096, disk_gb: 40, network: "paid-egress" } }
    )

    rediscovered = restarted_provider.clone(request_id: "request-1", image_id: "paid-macos", ownership_tags: tags("8"))

    expect([ first.fetch("vm_id"), second.fetch("vm_id") ]).to contain_exactly("paid-vm-1", "paid-vm-2")
    expect(rediscovered).to eq(second)
    expect(tart.clones).to eq(2)
    expect(softnet.configured).to contain_exactly(
      [ first.fetch("vm_id"), "paid-egress" ],
      [ second.fetch("vm_id"), "paid-egress" ]
    )
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

  it "recovers a destroy request after a host restart" do
    vm = provider.clone(request_id: "clone", image_id: "paid-macos", ownership_tags: tags).fetch("vm_id")
    provider.destroy(request_id: "destroy", vm_id: vm)
    restarted_provider = described_class.new(
      tart:, softnet:,
      profiles: { "ios-standard" => { cpu_cores: 2, memory_mib: 4096, disk_gb: 40, network: "paid-egress" } }
    )

    response = restarted_provider.destroy(request_id: "destroy", vm_id: vm)

    expect(response).to eq("vm_id" => vm, "state" => "destroyed")
    expect(tart.destroys).to eq(1)
  end

  it "returns Paid-owned inventory as host-service wire records" do
    tart.resources = [ { "vm_id" => "paid-vm-9", "tags" => tags, "state" => "running", "image_id" => "paid-macos" } ]

    resources = provider.inventory(ownership_tags: { "paid.run_id" => "7" })

    expect(resources).to eq([ {
      "vm_id" => "paid-vm-9",
      "tags" => tags,
      "state" => "running",
      "image_id" => "paid-macos"
    } ])
  end

  it "matches presence filters for reconciliation ownership tags" do
    tart.resources = [ {
      "vm_id" => "paid-vm-9",
      "tags" => tags.merge(
        "paid.account_id" => "3",
        "paid.project_id" => "5",
        "paid.created_at" => "2026-09-20T00:00:00Z"
      ),
      "state" => "running",
      "image_id" => "paid-macos"
    } ]
    filters = ExecutionRunners::REQUIRED_RECONCILIATION_TAG_NAMES.to_h { |name| [ "paid.#{name}", nil ] }

    resources = provider.inventory(ownership_tags: filters)

    expect(resources).to contain_exactly(include("vm_id" => "paid-vm-9"))
  end

  def tags(run_id = "7") = { "paid.run_id" => run_id, "paid.resource" => "apple_vm" }
end
