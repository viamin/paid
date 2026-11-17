# frozen_string_literal: true

class CloseoutVerificationJob < ApplicationJob
  queue_as :low_priority
  self.perform_timeout = 20.minutes

  discard_on ActiveRecord::RecordNotFound

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    CloseoutVerifications::Execute.call(agent_run:)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ApplicationJob::PerformTimeoutError => error
    CloseoutVerifications::Execute.record_exception!(agent_run:, error:)
    raise
  rescue StandardError => error
    CloseoutVerifications::Execute.record_exception!(agent_run:, error:) if agent_run&.status == "running"
    raise
  end
end
