# frozen_string_literal: true

# Subscribe to GitHub cache metrics events for structured logging.
# Events are emitted by Github::CacheService on cache hit, miss,
# and invalidation.
#
# Uses to_prepare instead of after_initialize so that the subscription
# re-runs after code reload in development, picking up the refreshed
# Github::CacheMetrics constant.
#
# Unsubscribes before re-subscribing to prevent duplicate listeners
# from accumulating across reloads.
Rails.application.config.to_prepare do
  Github::CacheMetrics::EVENTS.each do |event_name|
    ActiveSupport::Notifications.unsubscribe(event_name)
  end
  Github::CacheMetrics.subscribe!
end
