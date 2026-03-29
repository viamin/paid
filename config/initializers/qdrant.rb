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
      cred_key = Rails.application.credentials.dig(:qdrant, :api_key)
      env_key = ENV["QDRANT_API_KEY"]

      if cred_key.present?
        return cred_key
      end

      if env_key.present? && Rails.env.production?
        Rails.logger.warn(
          message: "qdrant.env_fallback_in_production",
          warning: "Using QDRANT_API_KEY env var in production. " \
                   "Prefer Rails credentials (qdrant.api_key) for secret management."
        )
        return env_key
      end

      if Rails.env.production?
        raise "QDRANT_API_KEY is required in production. " \
              "Set it via Rails credentials (qdrant.api_key) or QDRANT_API_KEY env var."
      end

      env_key
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
