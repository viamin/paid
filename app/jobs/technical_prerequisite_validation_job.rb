# frozen_string_literal: true

class TechnicalPrerequisiteValidationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @spec PARTIAL-CLOSEOUT-030
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless start!(agent_run)

    result = TechnicalPrerequisites::ValidateExecution.call(
      agent_run:, native_command: validation_metadata(agent_run).fetch("command")
    )
    finish!(agent_run, result)
  rescue Containers::Provision::Error, Containers::GitOperations::Error,
    ExecutionRunners::Error, Containers::McpProvisioner::Error => error
    fail!(agent_run, error)
  end

  private

  def start!(agent_run)
    agent_run.with_lock do
      return false unless agent_run.status == "queued"

      agent_run.update!(status: "running", started_at: Time.current)
    end
    true
  end

  def finish!(agent_run, result)
    agent_run.with_lock do
      return if agent_run.status == "cancelled"

      status = result.status == "completed" ? "completed" : "failed"
      error_message = terminal_message(result)
      agent_run.update!(status:, completed_at: Time.current, error_message:)
    end
  end

  def fail!(agent_run, error)
    agent_run&.update!(status: "failed", completed_at: Time.current, error_message: error.message)
    raise
  end

  def validation_metadata(agent_run)
    agent_run.external_metadata.fetch("technical_prerequisite_validation")
  end

  def terminal_message(result)
    return if result.success?

    result.evidence["error"] || result.setup_action || "Validation command exited non-zero."
  end
end
