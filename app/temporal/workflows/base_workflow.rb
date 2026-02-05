# frozen_string_literal: true

require "temporalio/workflow"
require "temporalio/retry_policy"

module Workflows
  class BaseWorkflow < Temporalio::Workflow::Definition
    DEFAULT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 1,
      maximum_interval: 60,
      maximum_attempts: 3
    )

    def activity_options(timeout: 300)
      {
        start_to_close_timeout: timeout,
        retry_policy: DEFAULT_RETRY_POLICY
      }
    end
  end
end
