# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Admission do
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-002

  let(:attempt) { create(:apple_verification_attempt, :committed) }

  let(:capacity) do
    {
      free_host_disk_gib: AppleVerificationAttempts::Config.min_free_host_disk_gib,
      free_memory_percent: AppleVerificationAttempts::Config.min_free_memory_percent,
      free_guest_disk_gib: AppleVerificationAttempts::Config.min_free_guest_disk_gib
    }
  end

  def call(active_vms:, critical_memory_samples:)
    described_class.call(
      attempt:,
      capacity:,
      active_vms:,
      critical_memory_samples:
    )
  end

  it "admits when every resource sits exactly at its threshold" do
    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms - 1,
      critical_memory_samples: AppleVerificationAttempts::Config.critical_memory_pressure_samples - 1
    )).to eq(
      described_class::Result.new(admitted: true, reason: nil, classification: nil)
    )
  end

  it "refuses when the active VM limit is reached" do
    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms,
      critical_memory_samples: 0
    )).to eq(
      described_class::Result.new(
        admitted: false,
        reason: "active VM limit reached",
        classification: "capacity_or_quota"
      )
    )
  end

  it "refuses when host disk is below the minimum" do
    capacity[:free_host_disk_gib] = AppleVerificationAttempts::Config.min_free_host_disk_gib - 1

    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms - 1,
      critical_memory_samples: 0
    )).to eq(
      described_class::Result.new(
        admitted: false,
        reason: "insufficient free host disk",
        classification: "capacity_or_quota"
      )
    )
  end

  it "refuses when free memory is below the minimum" do
    capacity[:free_memory_percent] = AppleVerificationAttempts::Config.min_free_memory_percent - 1

    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms - 1,
      critical_memory_samples: 0
    )).to eq(
      described_class::Result.new(
        admitted: false,
        reason: "insufficient free memory",
        classification: "capacity_or_quota"
      )
    )
  end

  it "refuses under sustained critical memory pressure" do
    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms - 1,
      critical_memory_samples: AppleVerificationAttempts::Config.critical_memory_pressure_samples
    )).to eq(
      described_class::Result.new(
        admitted: false,
        reason: "sustained critical memory pressure",
        classification: "capacity_or_quota"
      )
    )
  end

  it "refuses when guest disk is below the minimum" do
    capacity[:free_guest_disk_gib] = AppleVerificationAttempts::Config.min_free_guest_disk_gib - 1

    expect(call(
      active_vms: AppleVerificationAttempts::Config.max_active_vms - 1,
      critical_memory_samples: 0
    )).to eq(
      described_class::Result.new(
        admitted: false,
        reason: "insufficient free guest disk",
        classification: "capacity_or_quota"
      )
    )
  end

  describe ".host_safety_violation?" do
    it "is true under sustained critical memory pressure" do
      expect(described_class.host_safety_violation?(
        capacity:,
        critical_memory_samples: AppleVerificationAttempts::Config.critical_memory_pressure_samples
      )).to be(true)
    end

    it "is true when host disk is exhausted" do
      capacity[:free_host_disk_gib] = 0

      expect(described_class.host_safety_violation?(capacity:, critical_memory_samples: 0)).to be(true)
    end

    it "is false at normal thresholds" do
      expect(described_class.host_safety_violation?(capacity:, critical_memory_samples: 0)).to be(false)
    end
  end
end
