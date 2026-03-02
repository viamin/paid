# frozen_string_literal: true

module Paid
  @qdrant_mutex = Mutex.new

  class << self
    # Returns a QdrantClient instance. Connection is established lazily
    # on first call, not during Rails initialization. Thread-safe via Mutex
    # to prevent duplicate instances under concurrent Puma workers.
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
      ENV["QDRANT_API_KEY"]
    end
  end
end
