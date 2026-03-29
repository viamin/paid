# frozen_string_literal: true

class DiagnoseErrorJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)

    result = AgentRuns::DiagnoseError.call(agent_run: agent_run)

    if result.success?
      agent_run.update!(diagnosis_status: "completed", diagnosis_issue_url: result.issue_url)
    else
      agent_run.update!(diagnosis_status: "failed")
    end

    agent_run.project.broadcast_agent_run_detail_update(agent_run)
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
      agent_run&.project&.broadcast_agent_run_detail_update(agent_run)
    rescue => inner
      Rails.logger.error(
        message: "agent_execution.diagnose_error_status_update_failed",
        agent_run_id: agent_run_id,
        error: inner.message
      )
    end
  end
end
