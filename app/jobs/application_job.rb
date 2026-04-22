# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    Database::QueryMonitor.instrument("job", job_class: job.class.name) do
      block.call
    end
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
