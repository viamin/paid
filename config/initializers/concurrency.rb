# frozen_string_literal: true

Rails.application.config.x.max_concurrent_runs = Integer(ENV.fetch("MAX_CONCURRENT_RUNS", 2))
