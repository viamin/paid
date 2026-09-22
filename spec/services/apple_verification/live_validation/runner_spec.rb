# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-LIVE-002
# @spec APPLE-LIVE-004
# @spec APPLE-LIVE-005
# @spec APPLE-LIVE-006
RSpec.describe AppleVerification::LiveValidation::Runner do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:lifecycle) { AppleLiveValidationFakes::FakeLifecycle.new(%w[vm-a1 vm-a2 vm-b1 vm-b2 vm-c1 vm-c2 vm-r1 vm-r2 vm-r3 vm-r4 vm-r5 vm-r6]) }
  let(:dispatcher) { AppleLiveValidationFakes::FakeDispatcher.new }
  # The run factory mirrors bin/apple-verify-live's create_validation_run:
  # fresh validation runs start status "running", i.e. capacity-in-flight,
  # so the reconciler lane cannot claim their resources until the
  # choreography moves them out of the in-flight set.
  let(:ports) do
    AppleVerification::LiveValidation::Ports.new(
      lifecycle: lifecycle, dispatcher: dispatcher, reconciler: AppleLiveValidationFakes::FakeReconciler.new,
      run_factory: -> { create(:agent_run, :running, project: project) }
    )
  end
  let(:config) do
    AppleVerification::LiveValidation::Config.new(
      ports: ports, agent_run: agent_run, repeats: 2, image_id: "paid-macos", profile_id: "ios-standard", run_key: "t1"
    )
  end

  before { FeatureFlags.enable!(:apple_verification_workers, project: project) }

  def evidence_for(result, scenario_id)
    result.evidence.select { |row| row.scenario_id == scenario_id }
  end

  it "runs functional scenarios as repeated clean clones with per-repeat evidence" do
    result = described_class.new(config).run

    rows = evidence_for(result, "functional-smoke-ios-app")
    expect(rows).to all(have_attributes(status: :passed))
    expect(rows.size).to eq(2)
    expect(rows.map { |row| row.detail }).to all(match(/vm-a\d/))
    expect(lifecycle.provisioned_identifiers("functional-smoke-ios-app")).to eq(%w[vm-a1 vm-a2])
    expect(lifecycle.destroyed).to include("vm-a1", "vm-a2")
  end

  it "fails the repeat when a dispatched operation reports failure" do
    dispatcher.fail_operation_for("functional-colormatching-ios", "test")

    result = described_class.new(config).run

    rows = evidence_for(result, "functional-colormatching-ios")
    expect(rows).to contain_exactly(have_attributes(status: :passed), have_attributes(status: :failed, detail: /test/))
  end

  it "fails the repeat when a VM survives teardown" do
    lifecycle.leak_vm("vm-a1")

    result = described_class.new(config).run

    expect(evidence_for(result, "functional-smoke-ios-app").first).to have_attributes(status: :failed, detail: /inventory/)
  end

  it "fails the repeat when the provider reuses a VM across repeats" do
    ports.lifecycle = AppleLiveValidationFakes::FakeLifecycle.new(%w[vm-same vm-same])

    result = described_class.new(config).run

    rows = evidence_for(result, "functional-smoke-ios-app")
    expect(rows.last).to have_attributes(status: :failed, detail: /clean clone/)
  end

  it "records a gap for isolation scenarios without a diagnostics provider" do
    result = described_class.new(config).run

    rows = evidence_for(result, "isolation-keychain")
    expect(rows).to contain_exactly(have_attributes(status: :gap, detail: /diagnostics provider/))
  end

  it "records isolation evidence through the diagnostics provider" do
    ports.diagnostics = AppleLiveValidationFakes::FakeDiagnostics.new(
      "isolation-keychain" => { "status" => "denied", "detail" => "keychain empty" },
      "isolation-host-ssh" => { "status" => "exposed" }
    )

    result = described_class.new(config).run

    expect(evidence_for(result, "isolation-keychain")).to contain_exactly(have_attributes(status: :passed, detail: /keychain empty/))
    expect(evidence_for(result, "isolation-host-ssh")).to contain_exactly(have_attributes(status: :failed))
    expect(evidence_for(result, "isolation-devices")).to contain_exactly(have_attributes(status: :gap))
  end

  it "converges cancellation through the cleanup lane and asserts the ledger" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-cancellation").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("ledger entries deleted")
    expect(row.references).to include(hash_including("kind" => "execution_resource_ledger_entry"))
  end

  it "records a gap for the timeout scenario when no timeout policy is configured" do
    result = described_class.new(config).run

    expect(evidence_for(result, "recovery-timeout").sole).to have_attributes(status: :gap, detail: /timeout/)
  end

  it "converges partial provisioning failures before any VM exists" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-partial-provisioning").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("no VM left")
  end

  it "converges a control-plane restart by re-linking the same VM for the same request" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-control-plane-restart").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("re-linked")
  end

  it "tears down the re-linked control-plane-restart VM so it cannot leak" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-control-plane-restart").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("reconciled after teardown")
    expect(project.agent_runs.reload.map { |run| lifecycle.inventory(agent_run: run) }).to all(be_empty)
  end

  it "converges a host restart by cleaning the stopped VM through reconciliation" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-host-restart").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("ledger entries deleted")
  end

  it "converges orphan discovery after the owning run stops being in flight" do
    result = described_class.new(config).run

    row = evidence_for(result, "recovery-orphan-discovery").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("ledger entries deleted")
  end

  it "records capacity evidence with the measured figure" do
    ports.capacity_sampler = AppleLiveValidationFakes::FakeCapacitySampler.new([
      { "disk_free_gib" => 72.5, "memory_free_percent" => 31.0, "active_apple_vms" => 1, "agent_containers" => 3 },
      { "disk_free_gib" => 68.0, "memory_free_percent" => 26.5, "active_apple_vms" => 1, "agent_containers" => 4 }
    ])

    result = described_class.new(config).run

    row = evidence_for(result, "capacity-alongside-three-agent-containers").sole
    expect(row.status).to eq(:passed)
    expect(row.detail).to include("agent containers: 3-4")
    expect(row.detail).to include("disk free: 68.0-72.5 GiB")
  end

  it "fails capacity when a sample crosses an admission threshold" do
    ports.capacity_sampler = AppleLiveValidationFakes::FakeCapacitySampler.new([
      { "disk_free_gib" => 72.5, "memory_free_percent" => 31.0, "active_apple_vms" => 1, "agent_containers" => 3 },
      { "disk_free_gib" => 55.0, "memory_free_percent" => 31.0, "active_apple_vms" => 1, "agent_containers" => 3 }
    ])

    result = described_class.new(config).run

    expect(evidence_for(result, "capacity-alongside-three-agent-containers").sole).to have_attributes(status: :failed, detail: /60/)
  end

  it "fails capacity when fewer than three agent containers are active" do
    ports.capacity_sampler = AppleLiveValidationFakes::FakeCapacitySampler.new([
      { "disk_free_gib" => 72.5, "memory_free_percent" => 31.0, "active_apple_vms" => 1, "agent_containers" => 2 }
    ])

    result = described_class.new(config).run

    expect(evidence_for(result, "capacity-alongside-three-agent-containers").sole).to have_attributes(status: :failed, detail: /three/)
  end

  it "records a gap instead of raising when every capacity sample is degraded" do
    ports.capacity_sampler = AppleLiveValidationFakes::FakeCapacitySampler.new([
      { "disk_free_gib" => 72.5 },
      {}
    ])

    result = described_class.new(config).run

    expect(evidence_for(result, "capacity-alongside-three-agent-containers").sole)
      .to have_attributes(status: :gap, detail: /degraded/)
  end

  it "evaluates capacity against complete samples only when some samples are degraded" do
    ports.capacity_sampler = AppleLiveValidationFakes::FakeCapacitySampler.new([
      { "disk_free_gib" => 55.0, "memory_free_percent" => 31.0, "active_apple_vms" => 1, "agent_containers" => 3 },
      { "disk_free_gib" => 72.5 }
    ])

    result = described_class.new(config).run

    expect(evidence_for(result, "capacity-alongside-three-agent-containers").sole)
      .to have_attributes(status: :failed, detail: /60/)
  end

  it "leaves the archive reporting scenario as a gap until the report is written" do
    result = described_class.new(config).run

    expect(evidence_for(result, "report-archived-under-docs-rdrs").sole).to have_attributes(status: :gap)
  end
end
