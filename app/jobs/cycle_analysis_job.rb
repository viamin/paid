# frozen_string_literal: true

class CycleAnalysisJob < ApplicationJob
  queue_as :low_priority

  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-018
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless claim!(agent_run)

    result = CycleAnalyses::Analyze.call(agent_run:)
    agent_run.update!(status: "completed", completed_at: Time.current,
      verification_result: agent_run.verification_result.merge(CycleAnalyses::RESULT_KEY => result))
  rescue StandardError => error
    unless agent_run&.finished?
      message = AgentRun::ErrorMessageSanitizer.call(text: error.message)
      agent_run&.update!(status: "failed", completed_at: Time.current, error_message: message)
    end
    raise
  end

  private

  def claim!(agent_run)
    agent_run.with_lock do
      return false unless agent_run.status == "queued"

      agent_run.update!(status: "running", started_at: Time.current)
    end
    true
  end
end
