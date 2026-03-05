# frozen_string_literal: true

# Removes orphaned Docker workspace volumes that are no longer in use.
#
# Volumes become orphaned when:
# - Container cleanup fails or is skipped
# - A worker process crashes mid-execution
# - The container is removed externally but the volume persists
#
# Scheduled via GoodJob cron.
class DockerVolumeCleanupJob < ApplicationJob
  queue_as :maintenance

  VOLUME_PREFIX = "paid-workspace-"

  def perform
    volumes = list_paid_volumes
    return if volumes.empty?

    removed = 0
    volumes.each do |volume|
      agent_run_id = volume.id.delete_prefix(VOLUME_PREFIX)
      next if active_run?(agent_run_id)

      remove_volume(volume, agent_run_id)
      removed += 1
    end

    Rails.logger.info(
      message: "container_manager.volume_cleanup_complete",
      volumes_found: volumes.size,
      volumes_removed: removed
    )
  end

  private

  def list_paid_volumes
    Docker::Volume.all.select { |v| v.id.start_with?(VOLUME_PREFIX) }
  rescue Docker::Error::DockerError => e
    Rails.logger.error(
      message: "container_manager.volume_list_failed",
      error: e.message
    )
    []
  end

  def active_run?(agent_run_id)
    AgentRun.where(id: agent_run_id).active.exists?
  end

  def remove_volume(volume, agent_run_id)
    volume.remove
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.orphaned_volume_removal_failed",
      volume_name: volume.id,
      agent_run_id: agent_run_id,
      error: e.message
    )
  end
end
