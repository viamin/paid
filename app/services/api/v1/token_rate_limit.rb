# frozen_string_literal: true

module Api
  module V1
    # Per-token request budget for the /api/v1 namespace (MOBILE-API-004).
    # Keyed by token id — never by IP, so one account's mobile clients behind
    # a shared NAT cannot knock each other offline, and revoking a token kills
    # its quota pressure too. Each HTTP request counts exactly once: an SSE
    # stream is one request counted at stream start, never once per event.
    # This budget is separate from the per-user chat message rate limit
    # (ChatMessages::RateLimit).
    module TokenRateLimit
      MAX_REQUESTS = 600
      PERIOD = 5.minutes
      PERIOD_SECONDS = PERIOD.to_i
      FALLBACK_CACHE = ActiveSupport::Cache::MemoryStore.new

      module_function

      # Increments the fixed window that covers `now` and returns the number
      # of seconds until that window resets when the token has exceeded its
      # budget, nil otherwise.
      def retry_after_if_exceeded(token_id:, now: Time.current, cache: rate_limit_cache)
        bucket = now.to_i / PERIOD_SECONDS
        key = "#{cache_key(token_id:)}:#{bucket}"
        count = increment_count(cache:, key:)

        return nil if count <= MAX_REQUESTS

        PERIOD_SECONDS - (now.to_i % PERIOD_SECONDS)
      end

      def cache_key(token_id:)
        "api/v1/token_rate_limit:#{token_id}"
      end

      def increment_count(cache:, key:)
        count = cache.increment(key, 1, expires_in: PERIOD)
        return count unless count.nil?

        cache.write(key, 0, expires_in: PERIOD, unless_exist: true)
        cache.increment(key, 1, expires_in: PERIOD) || 1
      end

      def rate_limit_cache
        Rails.cache.is_a?(ActiveSupport::Cache::NullStore) ? FALLBACK_CACHE : Rails.cache
      end
    end
  end
end
