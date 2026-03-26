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
    checked = 0
    corrected = 0
    errors = 0

    ServiceContainer.running.find_each do |sc|
      checked += 1
      status = docker_container_status(sc.docker_container_id)

      case status
      when :not_running
        previous_id = sc.docker_container_id
        sc.update!(status: "stopped", docker_container_id: nil)
        corrected += 1
        Rails.logger.warn(
          message: "container_manager.service_container_drift_corrected",
          service_container_id: sc.id,
          name: sc.name,
          image: sc.image,
          previous_docker_id: previous_id
        )
      when :unknown
        errors += 1
        Rails.logger.warn(
          message: "container_manager.service_container_reconciliation_skipped",
          service_container_id: sc.id,
          name: sc.name,
          reason: "transient Docker API error"
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
      checked: checked,
      corrected: corrected,
      errors: errors
    )
  end

  private

  # Returns :running, :not_running, or :unknown.
  # :not_running means the container is confirmed missing or stopped.
  # :unknown means a transient API error occurred and we should not correct.
  def docker_container_status(container_id)
    return :not_running if container_id.blank?

    container = Docker::Container.get(container_id)
    container.json.dig("State", "Running") == true ? :running : :not_running
  rescue Docker::Error::NotFoundError
    :not_running
  rescue Docker::Error::DockerError, Excon::Error
    :unknown
  end
end
