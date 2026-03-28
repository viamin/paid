# frozen_string_literal: true

require "docker-api"

module Containers
  # Collects CPU and memory metrics from a running service container.
  class CollectServiceMetrics
    def self.call(...)
      new(...).call
    end

    def initialize(service_container:)
      @service_container = service_container
    end

    def call
      return unless collectible?

      stats = fetch_stats
      return stats if stats == :not_found
      return unless stats

      metric = nil
      ActiveRecord::Base.transaction do
        metric = record_metric(stats)
        update_service_container_summaries(metric)
      end
      metric
    rescue StandardError => e
      log_failure(e)
      nil
    end

    private

    attr_reader :service_container

    def collectible?
      service_container.docker_container_id.present? && service_container.running?
    end

    def fetch_stats
      container = Docker::Container.get(service_container.docker_container_id)
      raw = container.stats(stream: false)
      parse_stats(raw)
    rescue Docker::Error::NotFoundError
      Rails.logger.warn(
        message: "container_manager.service_container_not_found",
        service_container_id: service_container.id,
        name: service_container.name,
        container_id: service_container.docker_container_id
      )
      :not_found
    end

    def parse_stats(raw)
      DockerStatsParser.parse_stats(raw)
    end

    def record_metric(stats)
      ServiceContainerMetric.create!(
        service_container: service_container,
        container_id: service_container.docker_container_id,
        recorded_at: Time.current,
        **stats
      )
    end

    def update_service_container_summaries(metric)
      DockerStatsParser.update_summaries(model_class: ServiceContainer, id: service_container.id, metric: metric)
    end

    def log_failure(error)
      Rails.logger.warn(
        message: "container_manager.service_metrics_collection_failed",
        service_container_id: service_container.id,
        name: service_container.name,
        container_id: service_container.docker_container_id,
        error_class: error.class.name,
        error_message: error.message
      )
    end
  end
end
