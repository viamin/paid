# frozen_string_literal: true

class CycleAnalysisJob < ApplicationJob
  queue_as :low_priority

  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-019
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless claim!(agent_run)

    result = pending_sync?(agent_run) ? confirm_repair(agent_run) : analyze_and_repair(agent_run)
    publish_result!(agent_run, result)
  rescue StandardError => error
    fail_run!(agent_run, error) if agent_run
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

  def analyze_and_repair(agent_run)
    result = CycleAnalyses::Analyze.call(agent_run:)
    result["repair"] = CycleAnalyses::AutomaticRepair.call(agent_run:, recommendation: result.fetch("recommendation"))
    result
  end

  def confirm_repair(agent_run)
    agent_run.verification_result.fetch(CycleAnalyses::RESULT_KEY).deep_dup.tap do |result|
      result["repair"] = CycleAnalyses::Confirm.call(agent_run:)
    end
  end

  def pending_sync?(agent_run)
    agent_run.verification_result.dig(CycleAnalyses::RESULT_KEY, "repair", "status") == "pending_sync"
  end

  def publish_result!(agent_run, result)
    agent_run.with_lock do
      agent_run.reload
      return persist_cancelled_repair!(agent_run, result) if cancelled_with_pending_repair?(agent_run, result)
      return if agent_run.finished?

      agent_run.update!(status: "completed", completed_at: Time.current,
        verification_result: agent_run.verification_result.merge(CycleAnalyses::RESULT_KEY => result))
    end
  end

  def cancelled_with_pending_repair?(agent_run, result)
    agent_run.status == "cancelled" && result.dig("repair", "status") == "pending_sync"
  end

  def persist_cancelled_repair!(agent_run, result)
    agent_run.update!(verification_result: agent_run.verification_result.merge(CycleAnalyses::RESULT_KEY => result))
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
