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
