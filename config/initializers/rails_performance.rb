# frozen_string_literal: true

if defined?(RailsPerformance)
  RailsPerformance.setup do |config|
    config.redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    config.duration = 4.hours
    config.ignored_paths = [ "/rails/performance" ]
    config.enabled = true
  end
end
