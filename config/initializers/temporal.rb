# frozen_string_literal: true

require "temporalio/client"

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
