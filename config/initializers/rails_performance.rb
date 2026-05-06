# frozen_string_literal: true

if defined?(RailsPerformance)
  redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
  redis_client = Redis.new(url: redis_url)
  performance_enabled = true

  begin
    redis_client.ping
  rescue Redis::CannotConnectError, RedisClient::CannotConnectError, SocketError => error
    performance_enabled = false
    parsed = URI.parse(redis_url)
    Rails.logger.warn(
      message: "rails_performance.disabled",
      redis_host: parsed.host,
      redis_db: parsed.path,
      error_class: error.class.name,
      error_message: error.message
    )
  end

  RailsPerformance.setup do |config|
    config.redis = redis_client
    config.duration = 4.hours
    config.ignored_paths = [ "/rails/performance" ]
    config.enabled = performance_enabled
  end
end
