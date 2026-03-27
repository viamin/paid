# frozen_string_literal: true

module Containers
  # Shared Docker stats parsing logic for CPU, memory, and PID metrics.
  #
  # Used by both Containers::CollectMetrics (agent containers) and
  # Containers::CollectServiceMetrics (service containers) to ensure
  # consistent calculations across container types.
  module DockerStatsParser
    module_function

    def parse_stats(raw)
      {
        cpu_percent: parse_cpu(raw),
        memory_bytes: parse_memory_usage(raw),
        memory_limit_bytes: parse_memory_limit(raw),
        memory_percent: parse_memory_percent(raw),
        pids_count: parse_pids(raw)
      }
    end

    def parse_cpu(raw)
      cpu_stats = raw["cpu_stats"] || {}
      precpu_stats = raw["precpu_stats"] || {}

      cpu_delta = cpu_stats.dig("cpu_usage", "total_usage").to_f -
                  precpu_stats.dig("cpu_usage", "total_usage").to_f
      system_delta = cpu_stats["system_cpu_usage"].to_f -
                     precpu_stats["system_cpu_usage"].to_f
      online_cpus = cpu_stats["online_cpus"] ||
                    cpu_stats.dig("cpu_usage", "percpu_usage")&.length ||
                    1

      return 0.0 if system_delta <= 0 || cpu_delta < 0

      ((cpu_delta / system_delta) * online_cpus * 100.0).round(2)
    end

    def parse_memory_usage(raw)
      (raw["memory_stats"] || {})["usage"].to_i
    end

    def parse_memory_limit(raw)
      (raw["memory_stats"] || {})["limit"].to_i
    end

    def parse_memory_percent(raw)
      usage = parse_memory_usage(raw)
      limit = parse_memory_limit(raw)
      limit.positive? ? ((usage.to_f / limit) * 100.0).round(2) : 0.0
    end

    def parse_pids(raw)
      pids = raw.dig("pids_stats", "current")
      pids.nil? ? nil : pids.to_i
    end
  end
end
