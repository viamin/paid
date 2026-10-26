# frozen_string_literal: true

class TechnicalPrerequisiteValidationJob < ApplicationJob
  queue_as :low_priority
  self.perform_timeout = 10.minutes

  discard_on ActiveRecord::RecordNotFound

  # @spec PARTIAL-CLOSEOUT-030
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless start!(agent_run)

    result = TechnicalPrerequisites::ValidateExecution.call(
      agent_run:, native_command: recipe(agent_run).fetch("command")
    )
    finish!(agent_run, result)
  rescue ActiveRecord::RecordNotFound
    # The run was removed before the validation started; there is nothing to
    # record and nothing to retry.
    raise
  rescue StandardError => error
    # Job boundary: record the terminal failure on the run, then let the error
    # surface so the platform can alert on it (the same contract as
    # PreviewSessions::ProvisionJob).
    fail!(agent_run, error)
  end

  private

  # A validation run is claimed by this job alone: it is synthetic, so the
  # agent run queue never dispatches it. The run starts queued, moves to
  # running here, and a run that already reached a terminal state is never
  # re-executed.
  def start!(agent_run)
    agent_run.with_lock do
      return false unless agent_run.status == "queued"

      agent_run.update!(status: "running", started_at: Time.current)
    end
    true
  end

  def finish!(agent_run, result)
    agent_run.with_lock do
      agent_run.reload
      return if agent_run.finished?

      status = result.status == "completed" ? "completed" : "failed"
      agent_run.update!(status:, completed_at: Time.current, error_message: terminal_message(result))
    end
  end

  def fail!(agent_run, error)
    agent_run&.with_lock do
      agent_run.reload
      next if agent_run.finished?

      agent_run.update!(status: "failed", completed_at: Time.current, error_message: error.message)
    end
    raise error
  end

  def recipe(agent_run)
    agent_run.external_metadata.fetch(TechnicalPrerequisites::RECIPE_KEY)
  end

  def terminal_message(result)
    return if result.success?

    result.evidence["error"] || result.setup_action || "Validation command exited non-zero."
  end
end
