# frozen_string_literal: true

module Activities
  # Sets a retention TTL on the agent run's container so that cleanup is
  # deferred for post-failure diagnostics and possible work recovery.
  #
  # Called from the AgentExecutionWorkflow ensure block when the agent step
  # completed successfully but the workflow failed for an unknown reason.
  class RetainContainerActivity < BaseActivity
    activity_name "RetainContainer"

    DEFAULT_RETENTION_HOURS = 4
    LOW_DISK_RETENTION_HOURS = 1
    LOW_DISK_THRESHOLD_PERCENT = 85

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find_by(id: agent_run_id)
      unless agent_run
        logger.info(
          message: "agent_execution.retain_container_skipped_missing_run",
          agent_run_id: agent_run_id
        )
        return { agent_run_id: agent_run_id, retained: false }
      end

      return { agent_run_id: agent_run_id, retained: false } if agent_run.container_id.blank?

      retention_hours = compute_retention_hours
      retained_until = retention_hours.hours.from_now
      agent_run.update!(container_retained_until: retained_until)

      logger.info(
        message: "agent_execution.container_retained",
        agent_run_id: agent_run_id,
        container_id: agent_run.container_id,
        retained_until: retained_until.iso8601,
        retention_hours: retention_hours
      )

      { agent_run_id: agent_run_id, retained: true, retained_until: retained_until.iso8601 }
    end

    private

    def compute_retention_hours
      if disk_pressure?
        LOW_DISK_RETENTION_HOURS
      else
        DEFAULT_RETENTION_HOURS
      end
    end

    def disk_pressure?
      stat = `df --output=pcent / 2>/dev/null`.strip.split("\n").last
      return false unless stat

      usage_percent = stat.strip.delete_suffix("%").to_i
      usage_percent >= LOW_DISK_THRESHOLD_PERCENT
    rescue StandardError
      false
    end
  end
end
