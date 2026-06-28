# frozen_string_literal: true

require "timeout"

module Capacity
  class DockerSnapshot
    CACHE_KEY = "capacity/docker_snapshot/v1"
    CACHE_TTL = 15.seconds
    FETCH_TIMEOUT = 2.seconds
    PER_CONTAINER_TIMEOUT = 0.2.seconds
    MIN_SPIKE_MARGIN_BYTES = 256 * 1024 * 1024

    class << self
      def fetch(...)
        new(...).fetch
      end
    end

    def fetch
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { build_snapshot }
    end

    private

    def build_snapshot
      return unavailable_snapshot(reason: "unsupported_backend", confidence: "low") unless backend.identifier == "local"

      Timeout.timeout(FETCH_TIMEOUT) do
        running_containers = backend.list_containers(all: true).select { |container| running?(container) }
        metrics = collect_metrics(running_containers)
        categorized = categorize(running_containers, metrics)
        docker_memory_bytes = Docker.info["MemTotal"].to_i
        control_plane_memory_bytes = categorized[:paid_control_plane_memory_bytes]
        service_container_memory_bytes = categorized[:service_container_memory_bytes]
        unrelated_container_memory_bytes = categorized[:unrelated_container_memory_bytes]
        reserved_non_agent_bytes =
          control_plane_memory_bytes + service_container_memory_bytes + unrelated_container_memory_bytes
        spike_margin_bytes = [ ((control_plane_memory_bytes + service_container_memory_bytes) * 0.15).to_i, MIN_SPIKE_MARGIN_BYTES ].max

        {
          available: docker_memory_bytes.positive?,
          reason: docker_memory_bytes.positive? ? nil : "docker_memory_unavailable",
          confidence: metrics.size == running_containers.size ? "high" : "low",
          snapshot_at: Time.current,
          docker_memory_bytes: docker_memory_bytes,
          agent_memory_bytes: categorized[:agent_memory_bytes],
          paid_control_plane_memory_bytes: control_plane_memory_bytes,
          service_container_memory_bytes: service_container_memory_bytes,
          unrelated_container_memory_bytes: unrelated_container_memory_bytes,
          reserved_non_agent_bytes: reserved_non_agent_bytes,
          spike_margin_bytes: spike_margin_bytes,
          effective_agent_budget_bytes: [ docker_memory_bytes - reserved_non_agent_bytes - spike_margin_bytes, 0 ].max,
          running_container_count: running_containers.size,
          sampled_container_count: metrics.size
        }
      end
    rescue Timeout::Error
      unavailable_snapshot(reason: "docker_timeout", confidence: "low")
    rescue Docker::Error::DockerError, Excon::Error => e
      unavailable_snapshot(reason: "docker_error", confidence: "low", error_class: e.class.name, error_message: e.message)
    end

    def backend
      @backend ||= Containers.backend
    end

    def running?(container)
      state = container.info["State"]
      return state["Running"] == true if state.is_a?(Hash)

      state == "running"
    end

    def collect_metrics(containers)
      containers.each_with_object({}) do |container, metrics|
        metric = collect_container_metric(container)
        metrics[container.id] = metric if metric
      end
    end

    def collect_container_metric(container)
      Timeout.timeout(PER_CONTAINER_TIMEOUT) do
        raw = backend.container_stats(container, stream: false)
        Containers::DockerStatsParser.parse_stats(raw)
      end
    rescue Timeout::Error, Docker::Error::DockerError, Excon::Error
      nil
    end

    def categorize(containers, metrics)
      containers.each_with_object(
        agent_memory_bytes: 0,
        paid_control_plane_memory_bytes: 0,
        service_container_memory_bytes: 0,
        unrelated_container_memory_bytes: 0
      ) do |container, totals|
        metric = metrics[container.id]
        next unless metric

        labels = container.info.dig("Config", "Labels") || container.info["Labels"] || {}
        memory_bytes = metric[:memory_bytes].to_i

        if labels["paid.agent_run_id"].present?
          totals[:agent_memory_bytes] += memory_bytes
        elsif labels["paid.service_container_id"].present?
          totals[:service_container_memory_bytes] += memory_bytes
        elsif labels["com.docker.compose.project"].present?
          totals[:paid_control_plane_memory_bytes] += memory_bytes
        else
          totals[:unrelated_container_memory_bytes] += memory_bytes
        end
      end
    end

    def unavailable_snapshot(reason:, confidence:, **extra)
      {
        available: false,
        reason: reason,
        confidence: confidence,
        snapshot_at: Time.current,
        docker_memory_bytes: 0,
        agent_memory_bytes: 0,
        paid_control_plane_memory_bytes: 0,
        service_container_memory_bytes: 0,
        unrelated_container_memory_bytes: 0,
        reserved_non_agent_bytes: 0,
        spike_margin_bytes: 0,
        effective_agent_budget_bytes: 0,
        running_container_count: 0,
        sampled_container_count: 0
      }.merge(extra)
    end
  end
end
