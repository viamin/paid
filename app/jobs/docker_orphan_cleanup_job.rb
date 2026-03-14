# frozen_string_literal: true

# Removes orphaned Docker containers and volumes that are no longer in use.
#
# Resources become orphaned when:
# - A Temporal workflow crashes without executing its ensure block
# - Container cleanup fails or is skipped
# - A worker process crashes mid-execution
#
# Cleans up in order: agent containers, service containers, then volumes.
# Order matters because volumes can't be removed while containers reference them.
#
# Scheduled via GoodJob cron every 15 minutes.
class DockerOrphanCleanupJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "docker_orphan_cleanup"
  )

  VOLUME_PREFIX = "paid-workspace-"

  def perform
    agent_removed = cleanup_agent_containers
    service_removed = cleanup_service_containers
    volume_removed = cleanup_volumes

    Rails.logger.info(
      message: "container_manager.orphan_cleanup_complete",
      agent_containers_removed: agent_removed,
      service_containers_removed: service_removed,
      volumes_removed: volume_removed
    )
  end

  private

  # Phase 1: Remove agent containers whose runs are no longer active.
  def cleanup_agent_containers
    containers = list_containers_by_label("paid.agent_run_id")
    return 0 if containers.empty?

    agent_run_ids = containers.filter_map { |c| c.info.dig("Labels", "paid.agent_run_id") }
    numeric_ids = agent_run_ids.select { |id| id.match?(/\A\d+\z/) }
    active_ids = AgentRun.active.where(id: numeric_ids).pluck(:id).map(&:to_s).to_set

    removed = 0
    containers.each do |container|
      run_id = container.info.dig("Labels", "paid.agent_run_id")
      next if active_ids.include?(run_id)

      removed += 1 if stop_and_remove_container(container, "agent", run_id)
    end
    removed
  end

  # Phase 2: Remove service containers with zero active agent runs.
  def cleanup_service_containers
    containers = list_containers_by_label("paid.service_container=true")
    return 0 if containers.empty?

    removed = 0
    containers.each do |container|
      sc_id = container.info.dig("Labels", "paid.service_container_id")
      service_container = ServiceContainer.find_by(id: sc_id) if sc_id.present?

      if service_container.nil? || service_container.active_agent_run_count == 0
        if stop_and_remove_container(container, "service", sc_id)
          begin
            service_container&.update!(status: "stopped", docker_container_id: nil)
          rescue ActiveRecord::ActiveRecordError => e
            Rails.logger.warn(
              message: "container_manager.service_container_db_update_failed",
              service_container_id: sc_id,
              error_class: e.class.name,
              error: e.message
            )
          end
          removed += 1
        end
      end
    end
    removed
  end

  # Phase 3: Remove orphaned workspace volumes.
  def cleanup_volumes
    volumes = list_paid_volumes
    return 0 if volumes.empty?

    numeric_agent_run_ids = volumes
                              .map { |v| v.id.delete_prefix(VOLUME_PREFIX) }
                              .select { |id| id.match?(/\A\d+\z/) }
    active_ids = AgentRun.active.where(id: numeric_agent_run_ids).pluck(:id).map(&:to_s).to_set

    removed = 0
    volumes.each do |volume|
      agent_run_id = volume.id.delete_prefix(VOLUME_PREFIX)
      next if active_ids.include?(agent_run_id)

      removed += 1 if remove_volume(volume, agent_run_id)
    end
    removed
  end

  def list_containers_by_label(label)
    Docker::Container.all(all: true, filters: { label: [ label ] }.to_json)
  rescue Docker::Error::DockerError => e
    Rails.logger.error(
      message: "container_manager.container_list_failed",
      label: label,
      error: e.message
    )
    []
  end

  def stop_and_remove_container(container, kind, resource_id)
    container.stop(timeout: 10) if container.info.dig("State") == "running"
    container.delete(force: true)
    true
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.orphaned_container_removal_failed",
      kind: kind,
      resource_id: resource_id,
      error: e.message
    )
    false
  end

  def list_paid_volumes
    Docker::Volume.all.select { |v| v.id.start_with?(VOLUME_PREFIX) }
  rescue Docker::Error::DockerError => e
    Rails.logger.error(
      message: "container_manager.volume_list_failed",
      error: e.message
    )
    []
  end

  def remove_volume(volume, agent_run_id)
    volume.remove
    true
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.orphaned_volume_removal_failed",
      volume_name: volume.id,
      agent_run_id: agent_run_id,
      error: e.message
    )
    false
  end
end
