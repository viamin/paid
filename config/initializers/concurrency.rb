# frozen_string_literal: true

max_concurrent_runs = begin
  Integer(ENV.fetch("MAX_CONCURRENT_RUNS", "2"))
rescue ArgumentError, TypeError
  Rails.logger&.warn("Invalid MAX_CONCURRENT_RUNS value #{ENV['MAX_CONCURRENT_RUNS'].inspect}, defaulting to 2")
  2
end

if max_concurrent_runs < 1
  Rails.logger&.warn("MAX_CONCURRENT_RUNS=#{max_concurrent_runs} is less than 1, clamping to 1")
end

if max_concurrent_runs > 100
  Rails.logger&.warn("MAX_CONCURRENT_RUNS=#{max_concurrent_runs} exceeds upper bound, capping to 100")
end

Rails.application.config.x.max_concurrent_runs = max_concurrent_runs.clamp(1, 100)
