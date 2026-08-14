# frozen_string_literal: true

require "docker-api"

# Second-chance cleanup for Docker resources after an agent run completes.
#
# Enqueued by EnqueueJanitorActivity at the end of AgentExecutionWorkflow.
# If the in-workflow cleanup activities succeeded, this job is a fast no-op.
# If they failed (e.g. transient Docker daemon outage), this job provides a
# second attempt at container and volume removal, with retries handled by
# the job's retry policy.
class AgentRunResourceJanitorJob < ApplicationJob
  queue_as :maintenance

  retry_on Docker::Error::DockerError, wait: :polynomially_longer, attempts: 3

  VOLUME_PREFIX = "paid-workspace-"

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run
    return unless agent_run.finished?
    return if agent_run.container_retained?

    tracked_resource = ExecutionResource.schedule_cleanup_for!(agent_run: agent_run)
    container_cleaned = cleanup_container(agent_run)
    volume_cleaned = cleanup_volume(agent_run)
    ExecutionResource.mark_cleaned_for!(agent_run: agent_run) if tracked_resource&.active? || container_cleaned || volume_cleaned

    Rails.logger.info(
      message: "container_manager.janitor_complete",
      agent_run_id: agent_run_id,
      container_host: agent_run.container_host,
      workspace_volume_host: agent_run.workspace_volume_host,
      container_cleaned: container_cleaned,
      volume_cleaned: volume_cleaned
    )
  rescue Docker::Error::DockerError => e
    ExecutionResource.record_cleanup_failure_for!(agent_run: agent_run, error: e) if agent_run
    raise
  end

  private

  def cleanup_container(agent_run)
    container_id = agent_run.container_id
    return false if container_id.blank?

    backend = Containers.backend_for(agent_run.container_host)
    begin
      container = backend.get_container(container_id)
      begin
        backend.stop_container(container, timeout: 10)
      rescue Docker::Error::NotFoundError, Docker::Error::ClientError
        # Already stopped or gone
      end
      backend.delete_container(container, force: true, v: true)
    rescue Docker::Error::NotFoundError
      # Container already removed — clear the stale reference
    end

    agent_run.update_columns(container_id: nil) if agent_run.container_id.present?
    true
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.janitor_container_failed",
      agent_run_id: agent_run.id,
      container_id: agent_run.container_id,
      container_host: agent_run.container_host,
      error_class: e.class.name,
      error: e.message
    )
    raise
  end

  def cleanup_volume(agent_run)
    return false if agent_run.worktree_path.present?

    volume_name = "#{VOLUME_PREFIX}#{agent_run.id}"
    # container_host is blank from claim time until a backend records a real
    # resource, so resolve the owning host via workspace_volume_host — which
    # falls back to the planned admission host — to avoid probing the local
    # backend and leaking a remote volume when a worker died mid-provision.
    host = agent_run.workspace_volume_host
    backend = Containers.backend_for(host)
    backend.delete_volume(backend.get_volume(volume_name, host: host))
    true
  rescue Docker::Error::NotFoundError
    true # Volume already removed — treat as successfully cleaned
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.janitor_volume_failed",
      agent_run_id: agent_run.id,
      volume_name: "#{VOLUME_PREFIX}#{agent_run.id}",
      container_host: host,
      error_class: e.class.name,
      error: e.message
    )
    raise
  end
end
