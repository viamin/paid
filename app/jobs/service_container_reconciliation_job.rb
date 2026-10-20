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
      status, runtime_image = docker_container_status(sc)

      case status
      when :not_running
        previous_id = sc.docker_container_id
        previous_host = sc.container_host
        sc.update!(status: "stopped", docker_container_id: nil, container_host: nil)
        corrected += 1
        Rails.logger.warn(
          message: "container_manager.service_container_drift_corrected",
          service_container_id: sc.id,
          name: sc.name,
          image: sc.image,
          previous_docker_id: previous_id,
          previous_container_host: previous_host
        )
      when :unknown
        errors += 1
        Rails.logger.warn(
          message: "container_manager.service_container_reconciliation_skipped",
          service_container_id: sc.id,
          name: sc.name,
          container_host: sc.container_host,
          reason: "transient Docker API error"
        )
      when :running
        report_image_drift(sc, runtime_image)
        report_default_image_drift(sc, runtime_image)
      end
    rescue ActiveRecord::ActiveRecordError => e
      errors += 1
      Rails.logger.error(
        message: "container_manager.service_container_reconciliation_failed",
        service_container_id: sc.id,
        container_host: sc.container_host,
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

  # Returns the status and, when known, the Docker-reported image reference.
  # :not_running means the container is confirmed missing or stopped.
  # :unknown means a transient API error occurred and we should not correct.
  def docker_container_status(service_container)
    container_id = service_container.docker_container_id
    return [ :not_running, nil ] if container_id.blank?

    container = service_container.docker_backend.get_container(container_id)
    info = container.json
    status = info.dig("State", "Running") == true ? :running : :not_running
    [ status, info.dig("Config", "Image") ]
  rescue Docker::Error::NotFoundError
    [ :not_running, nil ]
  rescue Docker::Error::DockerError, Excon::Error
    [ :unknown, nil ]
  end

  # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
  def report_image_drift(service_container, runtime_image)
    return if runtime_image.blank? || runtime_image == service_container.image

    Rails.logger.warn(
      message: "container_manager.service_container_image_drift",
      service_container_id: service_container.id,
      name: service_container.name,
      requested_image: service_container.image,
      runtime_image: runtime_image,
      remediation: "drain consumers, then update the service container and recreate it"
    )
  end

  # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
  def report_default_image_drift(service_container, runtime_image)
    default_image = default_postgres_image
    return unless default_image && service_container.image.include?("postgres")
    return if service_container.image == default_image

    Rails.logger.warn(
      message: "container_manager.service_container_default_image_drift",
      service_container_id: service_container.id,
      name: service_container.name,
      configured_image: service_container.image,
      runtime_image: runtime_image,
      default_image: default_image,
      remediation: "drain consumers, then update the service container and recreate it"
    )
  end

  def default_postgres_image
    UserSetting.column_defaults.fetch("allowed_service_images", []).find { |image| image.start_with?("postgres:") }
  end
end
