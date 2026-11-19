# frozen_string_literal: true

module Activities
  # Completes a maintenance run as a report-only investigation (RDR-075 M01).
  # The agent's report is its recorded output; the run never pushes a branch
  # or opens a pull request. If the agent violated the write boundary and
  # produced changes, the run fails loudly with the collected evidence
  # preserved — a scan must never mutate source files, and the violation must
  # not be presented as a successful clean scan.
  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  class CompleteMaintenanceRunActivity < BaseActivity
    activity_name "CompleteMaintenanceRun"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      return result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run.id, phase_key: "complete_maintenance_run", phase_group: "post", agent_run: agent_run) do
        if input[:has_changes]
          fail_with_write_boundary_violation(agent_run)
        else
          complete_report_only(agent_run)
        end
        result(agent_run.reload)
      end
    end

    private

    def complete_report_only(agent_run)
      completed = agent_run.with_lock do
        agent_run.reload
        next false if agent_run.finished?

        persist_agent_report(agent_run)
        agent_run.complete!
      end
      return unless completed

      agent_run.log!("system", "Maintenance investigation completed report-only; no source files were changed.")
      ProcessRunQueueJob.perform_later
      logger.info(
        message: "agent_execution.maintenance_run_completed",
        agent_run_id: agent_run.id,
        status: agent_run.reload.status
      )
    end

    def persist_agent_report(agent_run)
      attributes = MaintenanceReports::AgentReport.parse(agent_run.agent_summary_tail_with_stderr_fallback)
      attributes = merge_tool_evidence(attributes, agent_run)
      MaintenanceReports::Persist.call(run: agent_run, **attributes)
    rescue MaintenanceReports::AgentReport::InvalidReport => e
      MaintenanceReports::Persist.call(run: agent_run,
        incomplete_checks: [ { "name" => "agent_report", "reason" => "parse_failure" } ])
      logger.warn(message: "agent_execution.maintenance_report_parse_failed", agent_run_id: agent_run.id,
        error_class: e.class.name, error: e.message)
    end

    # Tool output is collected before the agent starts and remains durable even
    # if the agent summarizes only a subset of it. Findings still require the
    # agent's structured provenance and semantic assessment.
    def merge_tool_evidence(attributes, agent_run)
      evidence = agent_run.external_metadata.fetch("maintenance_tool_evidence", {})
      return attributes unless evidence.is_a?(Hash)

      attributes.merge(
        completed_checks: Array(attributes[:completed_checks]) + Array(evidence["completed_checks"]),
        incomplete_checks: Array(attributes[:incomplete_checks]) + Array(evidence["incomplete_checks"])
      )
    end

    def fail_with_write_boundary_violation(agent_run)
      agent_run.update!(
        status: "failed",
        completed_at: Time.current,
        error_message: "Maintenance runs are report-only: the agent modified source files in its workspace. " \
                       "No changes were pushed. Re-run the investigation after reviewing the report evidence.",
        duration_seconds: agent_run.duration
      )
      agent_run.log!("system", "Report-only write boundary violated: workspace changes were discarded; nothing was pushed.")
      ProcessRunQueueJob.perform_later
      logger.warn(
        message: "agent_execution.maintenance_write_boundary_violation",
        agent_run_id: agent_run.id
      )
    end

    def result(agent_run)
      { agent_run_id: agent_run.id, success: agent_run.successful? }
    end
  end
end
