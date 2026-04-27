# frozen_string_literal: true

# Subscribe to GitHub cache metrics events for structured logging.
# Events are emitted by Github::CacheService on cache hit, miss,
# and invalidation.
#
# Uses to_prepare instead of after_initialize so that the subscription
# re-runs after code reload in development, picking up the refreshed
# Github::CacheMetrics constant.
#
# Unsubscribes only our own handles before re-subscribing to prevent
# duplicate listeners from accumulating across reloads, without
# removing subscribers registered by other code.
Rails.application.config.to_prepare do
  Array(@_github_cache_subscribers).each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
  @_github_cache_subscribers = Github::CacheMetrics.subscribe!
end
