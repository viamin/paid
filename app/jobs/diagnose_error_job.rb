# frozen_string_literal: true

class DiagnoseErrorJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)

    # Idempotency: skip if not in_progress (e.g., duplicate enqueue or re-run)
    agent_run.with_lock do
      return unless agent_run.diagnosis_status == "in_progress"
    end

    begin
      result = AgentRuns::DiagnoseError.call(agent_run: agent_run)

      if result.success?
        agent_run.update!(diagnosis_status: "completed", diagnosis_issue_url: result.issue_url)
      else
        agent_run.update!(diagnosis_status: "failed")
      end
    rescue => e
      Rails.logger.error(
        message: "agent_execution.diagnose_error_job_failed",
        agent_run_id: agent_run_id,
        error_class: e.class.name,
        error: e.message
      )

      begin
        agent_run = AgentRun.find_by(id: agent_run_id)
        agent_run&.update!(diagnosis_status: "failed")
      rescue => inner
        Rails.logger.error(
          message: "agent_execution.diagnose_error_status_update_failed",
          agent_run_id: agent_run_id,
          error: inner.message
        )
      end
    end

    begin
      agent_run&.project&.broadcast_agent_run_detail_update(agent_run)
    rescue => e
      Rails.logger.error(
        message: "agent_execution.diagnose_error_broadcast_failed",
        agent_run_id: agent_run_id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
