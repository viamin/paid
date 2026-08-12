# frozen_string_literal: true

module Paid
  @qdrant_mutex = Mutex.new

  class << self
    # Returns a QdrantClient instance. Connection is established lazily
    # on first call, not during Rails initialization. Thread-safe via Mutex
    # to prevent duplicate instances under concurrent threads/requests in a single process.
    #
    # @return [QdrantClient] Configured Qdrant client wrapper
    def qdrant_client
      @qdrant_mutex.synchronize do
        @qdrant_client ||= QdrantClient.new(
          url: qdrant_url,
          api_key: qdrant_api_key
        )
      end
    end

    # Resets the cached Qdrant client, allowing reconnection on next access.
    # Useful for recovering from connection failures or configuration changes.
    def reset_qdrant_client!
      @qdrant_mutex.synchronize do
        @qdrant_client = nil
      end
    end

    def qdrant_url
      ENV.fetch("QDRANT_URL", "http://localhost:6333")
    end

    def qdrant_api_key
      # Credentials take precedence; the `QDRANT_API_KEY` env var is the
      # documented alternative for ops who wire secrets through environment
      # injection (e.g. `bin/rails` runners, container env). The validator
      # (PROD-CONFIG-002) and docs/PRODUCTION_CONFIG.md both advertise the
      # env var as a valid source in production, so the runtime must honor
      # it too — otherwise an env-only deploy passes boot validation and
      # then crashes on the first `Paid.qdrant_client` call.
      cred_key = Rails.application.credentials.dig(:qdrant, :api_key)
      return cred_key if cred_key.present?

      ENV["QDRANT_API_KEY"].presence
    end

    def embedding_dimensions
      raw = ENV["EMBEDDING_DIMENSIONS"]
      return 3072 if raw.nil? || raw.strip.empty?

      begin
        value = Integer(raw, 10)
      rescue ArgumentError
        raise ArgumentError, "Invalid EMBEDDING_DIMENSIONS '#{raw}': must be a positive integer"
      end

      raise ArgumentError, "Invalid EMBEDDING_DIMENSIONS '#{raw}': must be a positive integer" if value <= 0

      value
    end
  end
end
