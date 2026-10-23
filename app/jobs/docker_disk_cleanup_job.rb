# frozen_string_literal: true

class DockerDiskCleanupJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  self.perform_timeout = 20.minutes.to_i

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "docker_disk_cleanup"
  )

  # @spec DOCKER-DISK-CLEANUP-001 DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-004
  def perform
    return unless ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"] == "true"

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Containers::PruneDockerDisk.new(protected_references: protected_references).call
    Rails.logger.info(
      message: "container_manager.disk_cleanup_complete",
      **result,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    )
  rescue => e
    Rails.logger.error(message: "container_manager.disk_cleanup_failed", error_class: e.class.name, error: e.message)
    raise
  end

  private

  def protected_references
    TenantContext.with_system_access do
      catalog = Containers::RuntimeImageCatalog.new(Rails.application.config_for(:agent_runtime_images))
      references = [ Containers::ImageResolver.base_image, *catalog.protected_references ]
      Project.find_each do |project|
        selection = Containers::RuntimeImageSelector.select(project: project)
        references.concat([ selection.requested_image, selection.image ])
      end
      AgentImage.find_each do |image|
        references.concat([ image.reference, image.digest_reference ])
      end
      references.uniq
    end
  end
end
