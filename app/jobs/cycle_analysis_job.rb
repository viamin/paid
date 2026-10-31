# frozen_string_literal: true

class CycleAnalysisJob < ApplicationJob
  queue_as :low_priority

  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-023
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless claim!(agent_run)

    result = CycleAnalyses::Analyze.call(agent_run:)
    result = result.merge("repair" => attempt_repair(agent_run, result)) unless cancelled_meanwhile?(agent_run)
    publish_result!(agent_run, result)
  rescue StandardError => error
    fail_run!(agent_run, error) if agent_run
    raise
  end

  private

  # A repair writes to GitHub, so it must never run for a run cancelled
  # during analysis — publish_result!'s own cancellation check happens too
  # late, after that write would already have landed.
  def cancelled_meanwhile?(agent_run) = agent_run.reload.finished?

  def attempt_repair(agent_run, result)
    snapshot = agent_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    decision = CycleAnalyses::ObviousCorrection.call(
      recommendation: result.fetch("recommendation"), coverage: result.fetch("coverage"), snapshot:
    )
    return { "status" => "not_attempted", "reason" => decision.reason } unless decision.candidate

    outcome = CycleAnalyses::ApplyRepair.call(
      agent_run:, candidate: decision.candidate, snapshot:, actor: agent_run.initiating_user
    )
    { "status" => outcome.status.to_s, "applied_changes" => outcome.applied_changes, "message" => outcome.message }
  end

  def claim!(agent_run)
    agent_run.with_lock do
      return false unless agent_run.status == "queued"

      agent_run.update!(status: "running", started_at: Time.current)
    end
    true
  end

  def publish_result!(agent_run, result)
    agent_run.with_lock do
      agent_run.reload
      return if agent_run.finished?

      agent_run.update!(status: "completed", completed_at: Time.current,
        verification_result: agent_run.verification_result.merge(CycleAnalyses::RESULT_KEY => result))
    end
  end

  def fail_run!(agent_run, error)
    agent_run.with_lock do
      agent_run.reload
      return if agent_run.finished?

      message = AgentRun::ErrorMessageSanitizer.call(text: error.message)
      agent_run.update!(status: "failed", completed_at: Time.current, error_message: message)
    end
  end
end
