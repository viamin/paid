# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-001
# @spec APPLE-ATTEMPT-002
RSpec.describe AppleVerificationAttempts::Admission do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  let(:host_metrics) do
    {
      disk_free_gib: 200.0,
      memory_free_percent: 60.0,
      guest_disk_free_gib: 30.0,
      memory_pressure_window: []
    }
  end

  let(:host_capacity) do
    AppleVerificationAttempts::HostCapacity.new(
      host_metrics_provider: -> { host_metrics }
    )
  end

  def admission_for(project:)
    described_class.new(project: project, host_capacity: host_capacity)
  end

  it "admits a queued attempt when all thresholds pass and the worker slot is free" do
    decision = admission_for(project: project).call

    expect(decision).to be_allowed
    expect(decision.reason).to eq("allowed")
    expect(decision.figures.active_apple_vms).to eq(0)
  end

  it "denies admission when the worker slot is already occupied" do
    create(:apple_verification_attempt, project: project, account: account, status: "running")

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("active_vm_limit")
    expect(decision.figures.active_apple_vms).to be >= 1
  end

  it "denies admission when host free disk is below the 60 GiB threshold" do
    host_metrics[:disk_free_gib] = 45.0

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("host_disk_low")
    expect(decision.thresholds[:min_host_disk_gib]).to eq(60)
  end

  it "denies admission when host free memory is below the 25% threshold" do
    host_metrics[:memory_free_percent] = 15.0

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("host_memory_low")
    expect(decision.thresholds[:min_host_memory_percent]).to eq(25)
  end

  it "denies admission during sustained critical memory pressure" do
    host_metrics[:memory_free_percent] = 2.0
    host_metrics[:memory_pressure_window] = [ 2.0, 2.0 ]

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("sustained_critical_memory_pressure")
  end

  it "reports a plain memory shortfall, not sustained pressure, for a single critical sample" do
    host_metrics[:memory_free_percent] = 2.0
    host_metrics[:memory_pressure_window] = []

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("host_memory_low")
  end

  it "requires the whole rolling window to be critical before denying for sustained pressure" do
    host_metrics[:memory_free_percent] = 2.0
    host_metrics[:memory_pressure_window] = [ 40.0, 2.0 ]

    decision = admission_for(project: project).call

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("host_memory_low")
  end

  it "honors operator-configurable defaults for thresholds" do
    decision = described_class.new(
      project: project, host_capacity: host_capacity,
      max_active_vms: 3, min_host_disk_gib: 30, min_host_memory_percent: 10,
      min_guest_disk_gib: 5, critical_memory_percent: 2
    ).call

    expect(decision).to be_allowed
    expect(decision.thresholds).to include(
      max_active_vms: 3,
      min_host_disk_gib: 30,
      min_host_memory_percent: 10,
      min_guest_disk_gib: 5,
      critical_memory_percent: 2
    )
  end

  describe "#recheck_admissions" do
    it "returns allowed when thresholds remain satisfied while a job runs" do
      decision = admission_for(project: project).recheck_admissions

      expect(decision).to be_allowed
    end

    it "denies new admissions when host disk crosses the threshold but does not declare host-safety" do
      host_metrics[:disk_free_gib] = 12.0

      decision = admission_for(project: project).recheck_admissions

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq("host_disk_low")
    end

    it "denies new admissions during sustained critical memory pressure" do
      host_metrics[:memory_free_percent] = 2.0
      host_metrics[:memory_pressure_window] = [ 2.0, 2.0 ]

      decision = admission_for(project: project).recheck_admissions

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq("sustained_critical_memory_pressure")
    end

    it "reports a plain memory shortfall, not sustained pressure, when the rolling window is incomplete" do
      host_metrics[:memory_free_percent] = 2.0
      host_metrics[:memory_pressure_window] = [ 2.0 ]

      decision = admission_for(project: project).recheck_admissions

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq("host_memory_low")
    end
  end
end
