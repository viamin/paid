# frozen_string_literal: true

class TechnicalPrerequisiteValidationJob < ApplicationJob
  queue_as :low_priority
  self.perform_timeout = 20.minutes

  discard_on ActiveRecord::RecordNotFound

  # @spec PARTIAL-CLOSEOUT-032 PARTIAL-CLOSEOUT-042 PARTIAL-CLOSEOUT-050
  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    start_result = start!(agent_run)
    return if start_result == :paused
    return handoff_terminal_validation(agent_run) unless start_result == :started

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
      return :terminal unless agent_run.status == "queued"

      pause_message = paused_performance_measurement_message(agent_run)
      if pause_message
        agent_run.update!(status: "failed", completed_at: Time.current, error_message: pause_message)
        return :paused
      end

      agent_run.update!(status: "running", started_at: Time.current)
    end
    :started
  end

  def paused_performance_measurement_message(agent_run)
    return unless recipe(agent_run)["performance_measurement"].present?

    TechnicalPrerequisites.scheduler_pause_message(agent_run.project)
  end

  def finish!(agent_run, result)
    audit_issue = nil
    agent_run.with_lock do
      agent_run.reload
      return if agent_run.finished?

      status = result.status == "completed" ? "completed" : "failed"
      agent_run.update!(status:, completed_at: Time.current, error_message: terminal_message(result))
      audit_issue = agent_run.issue if result.status != "cancelled"
    end
    # Scheduled outside the run lock: audit admission takes the issue lock and
    # creates continuation/agent-run rows, so a scheduling failure here must
    # not roll back the terminal status of the finished measurement run.
    PartialCloseouts::AutoAudit.call(issue: audit_issue) if audit_issue
  end

  # Every terminal validation changes (or makes unavailable) criterion-bound
  # evidence. AutoAudit deduplicates unchanged generations, so retrying this
  # handoff cannot loop while a new result receives a fresh assessment.
  # @spec PARTIAL-CLOSEOUT-050
  def handoff_terminal_validation(agent_run)
    return unless agent_run.finished?
    return if agent_run.status == "cancelled" || agent_run.issue.nil?

    PartialCloseouts::AutoAudit.call(issue: agent_run.issue)
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
