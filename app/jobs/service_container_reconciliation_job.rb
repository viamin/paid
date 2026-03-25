# frozen_string_literal: true

# Periodically reconciles DB service container records against actual Docker state.
#
# When Docker kills a container externally (OOM, crash, manual stop), the DB
# record still shows status: "running". This job detects such drift and corrects
# the DB, ensuring the next provisioning attempt starts a fresh container instead
# of assuming one is already alive.
#
# Scheduled via GoodJob cron every 5 minutes.
class ServiceContainerReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "service_container_reconciliation"
  )

  def perform
    corrected = 0
    errors = 0

    ServiceContainer.running.find_each do |sc|
      unless docker_container_running?(sc.docker_container_id)
        sc.update!(status: "stopped", docker_container_id: nil)
        corrected += 1
        Rails.logger.warn(
          message: "container_manager.service_container_drift_corrected",
          service_container_id: sc.id,
          name: sc.name,
          image: sc.image,
          previous_docker_id: sc.docker_container_id_before_last_save
        )
      end
    rescue ActiveRecord::ActiveRecordError => e
      errors += 1
      Rails.logger.error(
        message: "container_manager.service_container_reconciliation_failed",
        service_container_id: sc.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    Rails.logger.info(
      message: "container_manager.service_container_reconciliation_complete",
      checked: ServiceContainer.running.count + corrected,
      corrected: corrected,
      errors: errors
    )
  end

  private

  def docker_container_running?(container_id)
    return false if container_id.blank?

    container = Docker::Container.get(container_id)
    container.json.dig("State", "Running") == true
  rescue Docker::Error::DockerError
    false
  end
end
