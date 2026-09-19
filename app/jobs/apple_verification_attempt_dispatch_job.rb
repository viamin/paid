# frozen_string_literal: true

class AppleVerificationAttemptDispatchJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    attempt = AppleVerificationAttempt.find(attempt_id)
    attempt.with_lock do
      attempt.reload
      return unless attempt.queued? && attempt.temporal_workflow_id.blank?

      workflow_id = "apple-verification-attempt-#{attempt.id}"
      attempt.update!(temporal_workflow_id: workflow_id)
      start_workflow(attempt, workflow_id)
    end
  end

  private

  def start_workflow(attempt, workflow_id)
    Paid.temporal_client.start_workflow(
      Workflows::AppleVerificationWorkflow,
      { attempt_id: attempt.id },
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )
  end
end
