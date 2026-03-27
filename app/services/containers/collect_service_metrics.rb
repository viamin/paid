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
      cpu_stats = raw["cpu_stats"] || {}
      precpu_stats = raw["precpu_stats"] || {}
      mem_stats = raw["memory_stats"] || {}
      pids = raw.dig("pids_stats", "current")

      cpu_delta = cpu_stats.dig("cpu_usage", "total_usage").to_f -
        precpu_stats.dig("cpu_usage", "total_usage").to_f
      system_delta = cpu_stats["system_cpu_usage"].to_f -
        precpu_stats["system_cpu_usage"].to_f
      online_cpus = cpu_stats["online_cpus"] ||
        cpu_stats.dig("cpu_usage", "percpu_usage")&.length ||
        1

      cpu_percent = if system_delta <= 0 || cpu_delta < 0
        0.0
      else
        ((cpu_delta / system_delta) * online_cpus * 100.0).round(2)
      end

      memory_bytes = mem_stats["usage"].to_i
      memory_limit_bytes = mem_stats["limit"].to_i
      memory_percent = if memory_limit_bytes.positive?
        ((memory_bytes.to_f / memory_limit_bytes) * 100.0).round(2)
      else
        0.0
      end

      {
        cpu_percent: cpu_percent,
        memory_bytes: memory_bytes,
        memory_limit_bytes: memory_limit_bytes,
        memory_percent: memory_percent,
        pids_count: pids.nil? ? nil : pids.to_i
      }
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
      ServiceContainer.where(id: service_container.id).update_all(
        ServiceContainer.sanitize_sql_array(
          [
            <<~SQL.squish,
              peak_cpu_percent = GREATEST(COALESCE(peak_cpu_percent, 0), ?),
              peak_memory_bytes = GREATEST(COALESCE(peak_memory_bytes, 0), ?),
              avg_cpu_percent = (COALESCE(avg_cpu_percent, 0) * COALESCE(container_metrics_count, 0) + ?)::numeric / (COALESCE(container_metrics_count, 0) + 1),
              avg_memory_bytes = (COALESCE(avg_memory_bytes, 0) * COALESCE(container_metrics_count, 0) + ?)::numeric / (COALESCE(container_metrics_count, 0) + 1),
              container_metrics_count = COALESCE(container_metrics_count, 0) + 1
            SQL
            metric.cpu_percent,
            metric.memory_bytes,
            metric.cpu_percent,
            metric.memory_bytes
          ]
        )
      )
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
