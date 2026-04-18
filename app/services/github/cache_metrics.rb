# frozen_string_literal: true

module Github
  # Subscribes to ActiveSupport::Notifications events emitted by
  # {Github::CacheService} and logs structured cache hit/miss/invalidation
  # metrics.
  #
  # Attach in an initializer:
  #   Github::CacheMetrics.subscribe!
  class CacheMetrics
    EVENTS = %w[
      github_cache.hit
      github_cache.miss
      github_cache.invalidate
    ].freeze

    class << self
      def subscribe!
        EVENTS.each do |event_name|
          ActiveSupport::Notifications.subscribe(event_name) do |event|
            log_event(event)
          end
        end
      end

      private

      def log_event(event)
        payload = event.payload
        Rails.logger.info(
          message: event.name,
          component: "github_cache",
          duration_ms: event.duration&.round(2),
          **payload.except(:component)
        )
      end
    end
  end
end
