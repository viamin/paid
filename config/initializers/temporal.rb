# frozen_string_literal: true

# Suppress circular require warnings from temporalio gem's internal dependencies
# (temporalio/error.rb <-> temporalio/error/failure.rb)
original_verbose = $VERBOSE
$VERBOSE = nil
require "temporalio/client"
$VERBOSE = original_verbose

module Paid
  class << self
    def temporal_client
      @temporal_client ||= Temporalio::Client.connect(
        temporal_address,
        namespace: temporal_namespace
      )
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
