# frozen_string_literal: true

module AppleVerificationAttempts
  # Samples the fixed host-service readiness payload for scheduler admission.
  # Missing or malformed capacity data pauses the queue rather than guessing
  # that a clone is safe.
  # @spec APPLE-ATTEMPT-001
  class HostCapacity
    Snapshot = Data.define(:capacity, :critical_memory_samples)
    CRITICAL_MEMORY_CACHE_KEY = "apple_verification/critical_memory_samples"
    CRITICAL_MEMORY_CACHE_TTL = 15.minutes

    def self.from_environment
      endpoint = ENV["APPLE_VERIFICATION_HOST_URL"]
      token = ENV["APPLE_VERIFICATION_HOST_TOKEN"]
      return if endpoint.blank? || token.blank?

      new(host: AppleVerification::HostClient.new(endpoint:), token:)
    end

    def initialize(host:, token:, cache: Rails.cache)
      @host = host
      @token = token
      @cache = cache
    end

    def call(attempt:)
      readiness = host.call(version: AppleVerification::HostService::API_VERSION, operation: "readiness", payload: {}, token:)
      Snapshot.new(capacity: capacity(readiness, attempt), critical_memory_samples: critical_memory_samples(readiness))
    rescue AppleVerification::HostService::AuthenticationError, AppleVerification::HostService::UnsupportedRequestError, Faraday::Error => error
      Rails.logger.warn(message: "apple_verification.dispatch.capacity_unavailable", error_class: error.class.name)
      nil
    end

    private

    attr_reader :host, :token, :cache

    def capacity(readiness, attempt)
      memory = readiness.fetch("memory")
      disk = readiness.fetch("disk")
      {
        free_host_disk_gib: numeric!(disk.fetch("free_gib")),
        free_memory_percent: numeric!(memory.fetch("free_percent")),
        free_guest_disk_gib: guest_disk_gib(attempt)
      }
    end

    def guest_disk_gib(attempt)
      image = AppleVerificationImage.schedulable.find_by(account: attempt.account, digest: attempt.apple_worker_profile.image_digest)
      numeric!(image&.resources&.fetch("disk_gib", nil))
    end

    def numeric!(value)
      Float(value)
    rescue ArgumentError, TypeError
      raise AppleVerification::HostService::UnsupportedRequestError, "host readiness capacity is invalid"
    end

    def critical_memory_samples(readiness)
      return reset_critical_memory_samples unless readiness.dig("memory", "pressure") == "critical"

      cache.write(CRITICAL_MEMORY_CACHE_KEY, cache.read(CRITICAL_MEMORY_CACHE_KEY).to_i + 1, expires_in: CRITICAL_MEMORY_CACHE_TTL)
      cache.read(CRITICAL_MEMORY_CACHE_KEY)
    end

    def reset_critical_memory_samples
      cache.delete(CRITICAL_MEMORY_CACHE_KEY)
      0
    end
  end
end
