# frozen_string_literal: true

module Workflows
  # @spec APPLE-VERIFY-003
  class AppleVerificationWorkflow < BaseWorkflow
    def execute(input)
      run_activity(
        Activities::StartAppleVerificationAttemptActivity,
        { attempt_id: input.fetch(:attempt_id) },
        timeout: 30
      )
    end
  end
end
