# frozen_string_literal: true

module Containers
  # Short-lived ping probe for a single backend. Used by
  # BackendScheduler to honor the FALLBACK_FIRST_HEALTHY contract: a
  # host that is configured and provisioning-compatible but whose Docker
  # daemon is unreachable must not be selected, and a saturated preferred
  # daemon must fall through to a reachable fallback rather than
  # blocking the run.
  #
  # Results are cached in Rails.cache per backend for HEALTHY_TTL_SECONDS
  # so a queue pass does not pay a TCP round trip / TLS handshake per
  # host per candidate. The TTL is short enough that an actual daemon
  # outage flips the verdict from healthy to unhealthy within tens of
  # seconds; long enough that hundreds of candidates sharing one backend
  # share a single ping.
  class HealthCheck
    HEALTHY_TTL_SECONDS = 10
    UNHEALTHY_TTL_SECONDS = 5
    CACHE_PREFIX = "containers/health_check"

    Result = Data.define(:backend_identifier, :healthy, :pinged_at, :error_message) do
      def healthy?
        healthy == true
      end
    end

    def self.ping(backend)
      new(backend: backend).ping
    end

    def initialize(backend:)
      @backend = backend
    end

    def ping
      cached_result = read_cached_result
      return cached_result if cached_result

      result = probe
      write_result(result)
      result
    end

    private

    attr_reader :backend

    def probe
      backend.ping
      Result.new(
        backend_identifier: backend.identifier.to_s,
        healthy: true,
        pinged_at: Time.current,
        error_message: nil
      )
    rescue StandardError => e
      Result.new(
        backend_identifier: backend.identifier.to_s,
        healthy: false,
        pinged_at: Time.current,
        error_message: "#{e.class.name}: #{e.message}"
      )
    end

    def cache_key
      [ CACHE_PREFIX, backend.identifier ].join("/")
    end

    def read_cached_result
      raw = Rails.cache.read(cache_key)
      return unless raw

      Result.new(
        backend_identifier: raw[:backend_identifier].to_s,
        healthy: raw[:healthy] == true,
        pinged_at: raw[:pinged_at],
        error_message: raw[:error_message]
      )
    end

    def write_result(result)
      ttl = result.healthy ? HEALTHY_TTL_SECONDS : UNHEALTHY_TTL_SECONDS
      Rails.cache.write(cache_key, result.to_h, expires_in: ttl)
    end
  end
end
