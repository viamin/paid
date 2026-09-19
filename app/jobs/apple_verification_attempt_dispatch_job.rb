# frozen_string_literal: true

class AppleVerificationAttemptDispatchJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    attempt = AppleVerificationAttempt.find(attempt_id)
    return unless attempt.queued?

    workflow_id = "apple-verification-attempt-#{attempt.id}"
    Paid.temporal_client.start_workflow(
      "AppleVerificationWorkflow",
      { attempt_id: attempt.id },
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )
    attempt.update!(temporal_workflow_id: workflow_id)
  end
end
