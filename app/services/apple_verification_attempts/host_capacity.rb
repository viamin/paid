# frozen_string_literal: true

module AppleVerificationAttempts
  # Reads the trusted host's readiness payload at the admission boundary.
  # @spec APPLE-ATTEMPT-001
  class HostCapacity
    def self.configured?
      ENV["APPLE_VERIFICATION_HOST_URL"].present? && ENV["APPLE_VERIFICATION_HOST_TOKEN"].present?
    end

    def call
      CapacitySnapshot.new(
        free_host_disk_bytes: disk_free_bytes,
        free_memory_fraction: memory_free_fraction,
        free_guest_disk_bytes: disk_free_bytes,
        critical_memory_pressure: critical_memory_pressure?
      )
    end

    private

    def readiness
      @readiness ||= AppleVerification::HostClient.new(endpoint: ENV.fetch("APPLE_VERIFICATION_HOST_URL")).call(
        version: AppleVerification::HostService::API_VERSION, operation: "readiness", payload: {}, token: ENV.fetch("APPLE_VERIFICATION_HOST_TOKEN")
      )
    end

    def disk_free_bytes
      bytes = readiness.dig("disk", "free_bytes") || readiness["disk_free_bytes"]
      return bytes.to_i if bytes

      readiness.fetch("disk_free_gib").to_f.gigabytes.to_i
    end

    def memory_free_fraction
      percent = readiness.dig("memory", "free_percent") || readiness["memory_free_percent"]
      return percent.to_f / 100 if percent

      readiness.fetch("memory_free_fraction").to_f
    end

    def critical_memory_pressure?
      readiness.dig("memory", "pressure").to_s == "critical" || readiness["memory_pressure"].to_s == "critical"
    end
  end
end
