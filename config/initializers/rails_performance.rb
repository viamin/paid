# frozen_string_literal: true

if defined?(RailsPerformance)
  redis_url = ENV["REDIS_URL"]

  if redis_url
    RailsPerformance.setup do |config|
      config.redis = Redis.new(url: redis_url)
      config.duration = 4.hours
      config.enabled = true
    end
  else
    RailsPerformance.setup do |config|
      config.enabled = false
    end
  end
end
