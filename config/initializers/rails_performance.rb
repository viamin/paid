# frozen_string_literal: true

if defined?(RailsPerformance)
  RailsPerformance.setup do |config|
    config.redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    config.duration = 4.hours
    config.enabled = true
  end
end
