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

    def update_agent_run_summaries(metric)
      DockerStatsParser.update_summaries(model_class: AgentRun, id: agent_run.id, metric: metric)
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
