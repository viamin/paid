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
      nil
    end

    def parse_stats(raw)
      cpu = parse_cpu(raw)
      memory = parse_memory(raw)
      pids = raw.dig("pids_stats", "current")
      pids_count = pids.nil? ? nil : pids.to_i

      {
        cpu_percent: cpu,
        memory_bytes: memory[:usage],
        memory_limit_bytes: memory[:limit],
        memory_percent: memory[:percent],
        pids_count: pids_count
      }
    end

    def parse_cpu(raw)
      cpu_stats = raw["cpu_stats"] || {}
      precpu_stats = raw["precpu_stats"] || {}

      cpu_delta = cpu_stats.dig("cpu_usage", "total_usage").to_f -
                  precpu_stats.dig("cpu_usage", "total_usage").to_f
      system_delta = cpu_stats["system_cpu_usage"].to_f -
                     precpu_stats["system_cpu_usage"].to_f
      online_cpus = cpu_stats["online_cpus"] || 1

      return 0.0 if system_delta <= 0 || cpu_delta < 0

      ((cpu_delta / system_delta) * online_cpus * 100.0).round(2)
    end

    def parse_memory(raw)
      mem_stats = raw["memory_stats"] || {}
      usage = mem_stats["usage"].to_i
      limit = mem_stats["limit"].to_i
      percent = limit.positive? ? ((usage.to_f / limit) * 100.0).round(2) : 0.0

      { usage: usage, limit: limit, percent: percent }
    end

    def record_metric(stats)
      ContainerMetric.create!(
        agent_run: agent_run,
        container_id: agent_run.container_id,
        recorded_at: Time.current,
        **stats
      )
    end

    # Updates peak and average summaries incrementally using only the
    # newly inserted metric and the existing counter, avoiding O(n)
    # aggregate scans that grow more expensive as samples accumulate.
    def update_agent_run_summaries(metric)
      AgentRun.where(id: agent_run.id).update_all(
        AgentRun.sanitize_sql_array(
          [
            <<~SQL.squish,
              peak_cpu_percent = GREATEST(COALESCE(peak_cpu_percent, 0), ?),
              peak_memory_bytes = GREATEST(COALESCE(peak_memory_bytes, 0), ?),
              avg_cpu_percent = ROUND((COALESCE(avg_cpu_percent, 0) * (container_metrics_count - 1) + ?)::numeric / container_metrics_count, 2),
              avg_memory_bytes = ((COALESCE(avg_memory_bytes, 0) * (container_metrics_count - 1) + ?)::numeric / container_metrics_count)::bigint
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
        error_class: error.class.name,
        error_message: error.message
      )
    end
  end
end
