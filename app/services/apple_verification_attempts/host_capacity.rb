# frozen_string_literal: true

module AppleVerificationAttempts
  # Reads the trusted host's readiness payload at the admission boundary.
  # @spec APPLE-ATTEMPT-001
  class HostCapacity
    def self.configured?
      ENV["APPLE_VERIFICATION_HOST_URL"].present? && ENV["APPLE_VERIFICATION_HOST_TOKEN"].present?
    end

    def initialize(configuration: Configuration.new)
      @configuration = configuration
    end

    def call
      CapacitySnapshot.new(
        free_host_disk_bytes: disk_free_bytes,
        free_memory_fraction: memory_free_fraction,
        free_guest_disk_bytes: projected_guest_disk_free_bytes,
        critical_memory_pressure: critical_memory_pressure?
      )
    end

    private

    attr_reader :configuration

    def readiness
      @readiness ||= AppleVerification::HostClient.new(endpoint: ENV.fetch("APPLE_VERIFICATION_HOST_URL")).call(
        version: AppleVerification::HostService::API_VERSION, operation: "readiness", payload: {}, token: ENV.fetch("APPLE_VERIFICATION_HOST_TOKEN")
      )
    end

    # The host service reports a single host-level disk reading (nested
    # `disk.free_gib` / `disk.free_bytes` per the operator guide, with the
    # flat keys as a compatibility fallback). A payload without any disk
    # reading yields 0 so admission fails closed instead of crashing.
    def disk_free_bytes
      bytes = readiness.dig("disk", "free_bytes") || readiness["disk_free_bytes"]
      return bytes.to_i if bytes

      gib = readiness.dig("disk", "free_gib") || readiness["disk_free_gib"]
      gib.present? ? gib.to_f.gigabytes.to_i : 0
    end

    # A Tart guest disk is a sparse clone backed by host storage, and the
    # readiness payload has no guest-reported reading, so the projected free
    # guest disk after clone is the host free space beyond the reserved host
    # minimum. Admission compares this against the guest-disk minimum
    # (APPLE-ATTEMPT-001); it can fall short while the host reading passes.
    def projected_guest_disk_free_bytes
      disk_free_bytes - configuration.minimum_host_disk_bytes
    end

    # Missing disk or memory readings fail closed (0 free) so admission
    # reports a capacity refusal instead of crashing the scheduler.
    def memory_free_fraction
      percent = readiness.dig("memory", "free_percent") || readiness["memory_free_percent"]
      return percent.to_f / 100 if percent

      readiness["memory_free_fraction"].to_f
    end

    def critical_memory_pressure?
      readiness.dig("memory", "pressure").to_s == "critical" || readiness["memory_pressure"].to_s == "critical"
    end
  end
end
