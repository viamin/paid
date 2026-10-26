# frozen_string_literal: true

require "open3"

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

    # @spec CONTAINER-RUNTIME-048
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

      reservation = reserve_retention(agent_run)
      return { agent_run_id: agent_run_id, retained: false } unless reservation

      begin
        stop_retained_container(reservation)
      rescue StandardError
        restore_retention(agent_run.id, reservation)
        raise
      end

      logger.info(
        message: "agent_execution.container_retained",
        agent_run_id: agent_run_id,
        container_id: reservation[:container_id],
        retained_until: reservation[:retained_until].iso8601,
        retention_hours: reservation[:retention_hours]
      )

      { agent_run_id: agent_run_id, retained: true, retained_until: reservation[:retained_until].iso8601 }
    end

    private

    def reserve_retention(agent_run)
      agent_run.with_lock do
        next unless agent_run.status.in?(%w[failed retried]) && agent_run.container_id.present?

        hours = compute_retention_hours
        reservation = {
          container_id: agent_run.container_id, container_host: agent_run.container_host,
          previous_expiry: agent_run.container_retained_until,
          retained_until: hours.hours.from_now, retention_hours: hours
        }
        agent_run.update!(container_retained_until: reservation[:retained_until])
        reservation
      end
    end

    def restore_retention(agent_run_id, reservation)
      AgentRun.where(id: agent_run_id, container_id: reservation[:container_id],
        container_host: reservation[:container_host], container_retained_until: reservation[:retained_until])
        .update_all(container_retained_until: reservation[:previous_expiry])
    end

    def stop_retained_container(reservation)
      backend = Containers.backend_for(reservation[:container_host])
      container_id = reservation[:container_id]
      container = backend.get_container(container_id)
      return if container.info.dig("State", "Running") == false

      # docker-api rescues ServerError in #stop and accepts a string timeout key.
      # Re-inspect through the backend rather than trusting its cached info.
      backend.stop_container(container, **{ "timeout" => 10 })
      return if backend.get_container(container_id).info.dig("State", "Running") == false

      raise Docker::Error::ServerError, "Retained container #{container_id} did not stop"
    end

    def compute_retention_hours
      if disk_pressure?
        LOW_DISK_RETENTION_HOURS
      else
        DEFAULT_RETENTION_HOURS
      end
    end

    def disk_pressure?
      stdout, _stderr, status = Open3.capture3("df", "--output=pcent", "/")
      return false unless status.success?

      stat = stdout.strip.split("\n").last
      return false unless stat

      usage_percent = stat.strip.delete_suffix("%").to_i
      usage_percent >= LOW_DISK_THRESHOLD_PERCENT
    rescue StandardError
      false
    end
  end
end
