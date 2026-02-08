# frozen_string_literal: true

# Suppress circular require warnings from temporalio gem's internal dependencies
# (temporalio/error.rb <-> temporalio/error/failure.rb)
begin
  original_verbose = $VERBOSE
  $VERBOSE = nil
  require "temporalio/client"
ensure
  $VERBOSE = original_verbose
end

module Paid
  @temporal_mutex = Mutex.new

  class << self
    # Returns a connected Temporal client. Connection is established lazily
    # on first call, not during Rails initialization. Thread-safe via Mutex
    # to prevent duplicate connections under concurrent Puma workers.
    #
    # @return [Temporalio::Client] Connected Temporal client
    # @raise [Temporalio::Error] When connection fails
    def temporal_client
      @temporal_mutex.synchronize do
        @temporal_client ||= Temporalio::Client.connect(
          temporal_address,
          namespace: temporal_namespace
        )
      end
    end

    # Resets the cached Temporal client, allowing reconnection on next access.
    # Useful for recovering from connection failures or configuration changes.
    def reset_temporal_client!
      @temporal_mutex.synchronize do
        @temporal_client = nil
      end
    end

    # Supports both TEMPORAL_ADDRESS (used in docker-compose services) and
    # TEMPORAL_HOST (used in .env.example / app container config).
    def temporal_address
      ENV["TEMPORAL_ADDRESS"] || ENV.fetch("TEMPORAL_HOST", "localhost:7233")
    end

    def temporal_namespace
      ENV.fetch("TEMPORAL_NAMESPACE", "default")
    end

    def temporal_ui_url
      ENV.fetch("TEMPORAL_UI_URL", "http://localhost:8080")
    end

    def task_queue
      ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    end
  end
end
