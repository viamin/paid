# frozen_string_literal: true

# Subscribe to GitHub cache metrics events for structured logging.
# Events are emitted by Github::CacheService on cache hit, miss,
# and invalidation.
Rails.application.config.after_initialize do
  Github::CacheMetrics.subscribe!
end
