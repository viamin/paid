# frozen_string_literal: true

require "temporalio/workflow"
require "temporalio/retry_policy"

module Workflows
  # Base class for all Temporal workflows in this application.
  #
  # Inherits from Temporalio::Workflow::Definition as per the temporalio gem v1.2.0 API.
  # Workflows must implement an `execute` method which will be called by the Temporal worker.
  class BaseWorkflow < Temporalio::Workflow::Definition
    DEFAULT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 1,
      max_interval: 60,
      max_attempts: 3
    )

    def activity_options(timeout: 300)
      {
        start_to_close_timeout: timeout,
        retry_policy: DEFAULT_RETRY_POLICY
      }
    end
  end
end
