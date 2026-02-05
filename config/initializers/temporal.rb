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
  class << self
    # Returns a connected Temporal client. Connection is established lazily
    # on first call, not during Rails initialization.
    #
    # @return [Temporalio::Client] Connected Temporal client
    # @raise [Temporalio::Error] When connection fails
    def temporal_client
      @temporal_client ||= Temporalio::Client.connect(
        temporal_address,
        namespace: temporal_namespace
      )
    end

    # Resets the cached Temporal client, allowing reconnection on next access.
    # Useful for recovering from connection failures or configuration changes.
    def reset_temporal_client!
      @temporal_client = nil
    end

    def temporal_address
      ENV.fetch("TEMPORAL_ADDRESS", "localhost:7233")
    end

    def temporal_namespace
      ENV.fetch("TEMPORAL_NAMESPACE", "default")
    end

    def task_queue
      ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    end
  end
end
