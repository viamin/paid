# frozen_string_literal: true

# Second-chance cleanup for Docker resources after an agent run completes.
#
# Enqueued by EnqueueJanitorActivity at the end of AgentExecutionWorkflow.
# If the in-workflow cleanup activities succeeded, this job is a fast no-op.
# If they failed (e.g. transient Docker daemon outage), this job retries
# container and volume removal after a short delay.
class AgentRunResourceJanitorJob < ApplicationJob
  queue_as :maintenance

  retry_on Docker::Error::DockerError, wait: :polynomially_longer, attempts: 3

  VOLUME_PREFIX = "paid-workspace-"

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run
    return if agent_run.active?

    container_cleaned = cleanup_container(agent_run)
    volume_cleaned = cleanup_volume(agent_run)

    Rails.logger.info(
      message: "container_manager.janitor_complete",
      agent_run_id: agent_run_id,
      container_cleaned: container_cleaned,
      volume_cleaned: volume_cleaned
    )
  end

  private

  def cleanup_container(agent_run)
    container_id = agent_run.container_id
    return false if container_id.blank?

    begin
      container = Docker::Container.get(container_id)
      begin
        container.stop(timeout: 10)
      rescue Docker::Error::NotFoundError, Docker::Error::ClientError
        # Already stopped or gone
      end
      container.delete(force: true)
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
      error_class: e.class.name,
      error: e.message
    )
    raise
  end

  def cleanup_volume(agent_run)
    return false if agent_run.worktree_path.present?

    volume_name = "#{VOLUME_PREFIX}#{agent_run.id}"
    Docker::Volume.get(volume_name).remove
    true
  rescue Docker::Error::NotFoundError
    true # Volume already removed — treat as successfully cleaned
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.janitor_volume_failed",
      agent_run_id: agent_run.id,
      volume_name: "#{VOLUME_PREFIX}#{agent_run.id}",
      error_class: e.class.name,
      error: e.message
    )
    raise
  end
end
