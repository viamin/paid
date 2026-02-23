# frozen_string_literal: true

max_concurrent_runs = begin
  Integer(ENV.fetch("MAX_CONCURRENT_RUNS", "2"))
rescue ArgumentError, TypeError
  Rails.logger&.warn("Invalid MAX_CONCURRENT_RUNS value #{ENV['MAX_CONCURRENT_RUNS'].inspect}, defaulting to 2")
  2
end

Rails.application.config.x.max_concurrent_runs = [ max_concurrent_runs, 1 ].max
