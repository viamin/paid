# frozen_string_literal: true

module ChatMessages
  module RateLimit
    MAX_REQUESTS = 60
    PERIOD = 1.minute
    FALLBACK_CACHE = ActiveSupport::Cache::MemoryStore.new

    module_function

    def identifier(user_id:, chat_session_id:)
      "#{user_id}:#{chat_session_id}"
    end

    def exceeded?(user_id:, chat_session_id:, cache: rate_limit_cache)
      key = cache_key(user_id:, chat_session_id:)
      count = cache.increment(key, 1, expires_in: PERIOD)
      count ||= initialize_count(cache:, key:)
      count > MAX_REQUESTS
    end

    def cache_key(user_id:, chat_session_id:)
      "chat_messages:rate_limit:#{identifier(user_id:, chat_session_id:)}"
    end

    def initialize_count(cache:, key:)
      cache.write(key, 1, expires_in: PERIOD)
      1
    end

    def rate_limit_cache
      Rails.cache.is_a?(ActiveSupport::Cache::NullStore) ? FALLBACK_CACHE : Rails.cache
    end
  end
end
