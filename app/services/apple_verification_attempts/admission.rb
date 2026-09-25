# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides whether a queued attempt may start a verification VM, and whether
  # a running host must be stopped for host safety.
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-002
  class Admission
    Result = Data.define(:admitted, :reason, :classification)

    def self.call(attempt:, capacity:, active_vms:, critical_memory_samples:)
      new(attempt:, capacity:, active_vms:, critical_memory_samples:).call
    end

    def self.host_safety_violation?(capacity:, critical_memory_samples:)
      critical_memory_samples >= Config.critical_memory_pressure_samples ||
        capacity[:free_host_disk_gib] <= 0
    end

    def initialize(attempt:, capacity:, active_vms:, critical_memory_samples:)
      @attempt = attempt
      @capacity = capacity
      @active_vms = active_vms
      @critical_memory_samples = critical_memory_samples
    end

    def call
      reason = refusal_reason
      return Result.new(admitted: false, reason:, classification: "capacity_or_quota") if reason

      Result.new(admitted: true, reason: nil, classification: nil)
    end

    private

    def refusal_reason
      return "active VM limit reached" if @active_vms >= Config.max_active_vms
      return "insufficient free host disk" if @capacity[:free_host_disk_gib] < Config.min_free_host_disk_gib
      return "insufficient free memory" if @capacity[:free_memory_percent] < Config.min_free_memory_percent
      return "sustained critical memory pressure" if @critical_memory_samples >= Config.critical_memory_pressure_samples
      "insufficient free guest disk" if @capacity[:free_guest_disk_gib] < Config.min_free_guest_disk_gib
    end
  end
end
