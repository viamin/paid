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
# Scheduled via GoodJob cron every 5 minutes.
class DockerOrphanCleanupJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "docker_orphan_cleanup"
  )

  VOLUME_PREFIX = "paid-workspace-"
  POOL_VOLUME_PREFIX = "paid-pool-workspace-"

  def perform
    agent_removed = cleanup_agent_containers
    pool_removed = cleanup_pool_containers
    service_removed = cleanup_service_containers
    volume_result = cleanup_volumes

    Rails.logger.info(
      message: "container_manager.orphan_cleanup_complete",
      agent_containers_removed: agent_removed,
      pool_containers_removed: pool_removed,
      service_containers_removed: service_removed,
      volumes_found: volume_result[:found],
      volumes_removed: volume_result[:removed],
      volumes_failed: volume_result[:failed],
      volumes_active: volume_result[:active],
      volumes_retained: volume_result[:retained]
    )
  end

  private

  # Phase 1: Remove agent containers whose runs are no longer active.
  # Skips containers for runs with an unexpired retention TTL.
  def cleanup_agent_containers
    containers = list_containers_by_label("paid.agent_run_id")
    return 0 if containers.empty?

    agent_run_ids = containers.filter_map { |c| c.info.dig("Labels", "paid.agent_run_id") }
    numeric_ids = agent_run_ids.select { |id| id.match?(/\A\d+\z/) }
    active_ids = AgentRun.active.where(id: numeric_ids).pluck(:id).map(&:to_s).to_set
    retained_ids = AgentRun.where(id: numeric_ids)
      .where("container_retained_until > ?", Time.current)
      .pluck(:id).map(&:to_s).to_set

    removed = 0
    containers.each do |container|
      run_id = container.info.dig("Labels", "paid.agent_run_id")
      next if active_ids.include?(run_id)
      next if retained_ids.include?(run_id)

      removed += 1 if stop_and_remove_container(container, "agent", run_id)
    end
    removed
  end

  # Phase 2: Remove stale warm-pool containers no longer tracked in the DB.
  def cleanup_pool_containers
    containers = list_containers_by_label("paid.container_pool=true")
    return 0 if containers.empty?

    removed = 0
    containers.each do |container|
      entry_id = container.info.dig("Labels", "paid.container_pool_entry_id")
      entry = ContainerPoolEntry.find_by(id: entry_id) if entry_id.present?
      next if entry&.status.in?(%w[warm warming claimed]) && pool_entry_active?(entry)

      removed += 1 if stop_and_remove_container(container, "pool", entry_id)
      entry&.destroy!
    end
    removed
  end

  # Phase 3: Remove service containers with zero active agent runs.
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

  # Phase 4: Remove orphaned workspace volumes.
  # Skips volumes for runs with an unexpired retention TTL.
  def cleanup_volumes
    volumes = list_paid_volumes
    return { found: 0, removed: 0, failed: 0, active: 0 } if volumes.empty?

    numeric_agent_run_ids = volumes
                              .map { |v| v.id.delete_prefix(VOLUME_PREFIX) }
                              .select { |id| id.match?(/\A\d+\z/) }
    active_ids = AgentRun.active.where(id: numeric_agent_run_ids).pluck(:id).map(&:to_s).to_set
    retained_ids = AgentRun.where(id: numeric_agent_run_ids)
      .where("container_retained_until > ?", Time.current)
      .pluck(:id).map(&:to_s).to_set

    removed = 0
    failed = 0
    active = 0
    retained = 0
    volumes.each do |volume|
      if volume.id.start_with?(POOL_VOLUME_PREFIX)
        if active_pool_volume_names.include?(volume.id)
          active += 1
          next
        end

        if remove_volume(volume, nil)
          removed += 1
        else
          failed += 1
        end
        next
      end

      agent_run_id = volume.id.delete_prefix(VOLUME_PREFIX)
      if active_ids.include?(agent_run_id)
        active += 1
        next
      end
      if retained_ids.include?(agent_run_id)
        retained += 1
        next
      end

      if remove_volume(volume, agent_run_id)
        removed += 1
      else
        failed += 1
      end
    end
    { found: volumes.size, removed: removed, failed: failed, active: active, retained: retained }
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
    begin
      container.stop(timeout: 10)
    rescue Docker::Error::NotFoundError, Docker::Error::ClientError
      # Already stopped or gone
    end
    begin
      container.delete(force: true, v: true)
    rescue Docker::Error::NotFoundError
      # Container disappeared between stop and delete (race condition)
    end
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
    Docker::Volume.all.select { |v| v.id.start_with?(VOLUME_PREFIX) || v.id.start_with?(POOL_VOLUME_PREFIX) }
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
  rescue Docker::Error::NotFoundError
    true # Volume disappeared between listing and removal (race condition)
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.orphaned_volume_removal_failed",
      volume_name: volume.id,
      agent_run_id: agent_run_id,
      error: e.message
    )
    false
  end

  def pool_entry_active?(entry)
    return true if entry.status == "warm"
    return entry.created_at >= ContainerPoolEntry::WARMING_STALE_AFTER.ago if entry.status == "warming"

    entry.agent_run&.status.in?(AgentRun::UNFINISHED_STATUSES)
  end

  def active_pool_volume_names
    @active_pool_volume_names ||= begin
      warm_names = ContainerPoolEntry.warm.pluck(:workspace_volume)
      warming_names = ContainerPoolEntry.active_warming.pluck(:workspace_volume)
      claimed_names = ContainerPoolEntry.claimed
        .joins(:agent_run)
        .where(agent_runs: { status: AgentRun::UNFINISHED_STATUSES })
        .pluck(:workspace_volume)

      (warm_names + warming_names + claimed_names).to_set
    end
  end
end
