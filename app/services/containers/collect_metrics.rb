# frozen_string_literal: true

require "docker-api"

module Containers
  # Collects CPU and memory metrics from a running Docker container.
  #
  # Reads a single stats snapshot from the Docker API and persists it
  # as a ContainerMetric record. Updates peak/average summary fields
  # on the associated AgentRun for easy querying.
  #
  # @example
  #   Containers::CollectMetrics.call(agent_run: agent_run)
  class CollectMetrics
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return unless collectible?

      stats = fetch_stats
      return stats if stats == :not_found
      return unless stats

      metric = nil
      ActiveRecord::Base.transaction do
        metric = record_metric(stats)
        update_agent_run_summaries(metric)
      end
      metric
    rescue StandardError => e
      log_failure(e)
      nil
    end

    private

    attr_reader :agent_run

    def collectible?
      agent_run.container_id.present? && agent_run.running?
    end

    def fetch_stats
      container = Docker::Container.get(agent_run.container_id)
      raw = container.stats(stream: false)
      parse_stats(raw)
    rescue Docker::Error::NotFoundError
      Rails.logger.warn(
        message: "container_manager.container_not_found",
        agent_run_id: agent_run.id,
        container_id: agent_run.container_id
      )
      :not_found
    end

    def parse_stats(raw)
      DockerStatsParser.parse_stats(raw)
    end

    def record_metric(stats)
      ContainerMetric.create!(
        agent_run: agent_run,
        container_id: agent_run.container_id,
        recorded_at: Time.current,
        **stats
      )
    end

    # Updates peak/average summaries and increments container_metrics_count
    # in a single UPDATE, avoiding the extra write that counter_cache would
    # cause (reviewer feedback: consolidate to one row update per sample).
    def update_agent_run_summaries(metric)
      AgentRun.where(id: agent_run.id).update_all(
        AgentRun.sanitize_sql_array(
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
        message: "container_manager.metrics_collection_failed",
        agent_run_id: agent_run.id,
        container_id: agent_run.container_id,
        error_class: error.class.name,
        error_message: error.message
      )
    end
  end
end
