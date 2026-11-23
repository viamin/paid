# frozen_string_literal: true

module Containers
  # Shared Docker stats parsing logic for CPU, memory, and PID metrics.
  #
  # Used by both Containers::CollectMetrics (agent containers) and
  # Containers::CollectServiceMetrics (service containers) to ensure
  # consistent calculations across container types.
  module DockerStatsParser
    module_function

    InvalidStatsError = Class.new(StandardError)

    # @spec CONTAINER-RUNTIME-005
    def parse_stats(raw)
      raise InvalidStatsError, "docker stats payload must be a hash" unless raw.is_a?(Hash)

      {
        cpu_percent: parse_cpu(raw),
        memory_bytes: parse_memory_usage(raw),
        memory_limit_bytes: parse_memory_limit(raw),
        memory_percent: parse_memory_percent(raw),
        pids_count: parse_pids(raw)
      }
    end

    def parse_cpu(raw)
      cpu_stats = required_section(raw, "cpu_stats")
      precpu_stats = required_section(raw, "precpu_stats")
      cpu_usage = required_section(cpu_stats, "cpu_usage", parent: "cpu_stats")
      precpu_usage = required_section(precpu_stats, "cpu_usage", parent: "precpu_stats")

      cpu_delta = required_number(cpu_usage, "total_usage", parent: "cpu_stats.cpu_usage") -
                  required_number(precpu_usage, "total_usage", parent: "precpu_stats.cpu_usage")
      system_delta = required_number(cpu_stats, "system_cpu_usage", parent: "cpu_stats") -
                     required_number(precpu_stats, "system_cpu_usage", parent: "precpu_stats")
      online_cpus = online_cpu_count(cpu_stats, cpu_usage)

      return 0.0 if system_delta <= 0 || cpu_delta < 0

      ((cpu_delta.to_f / system_delta) * online_cpus * 100.0).round(2)
    end

    def parse_memory_usage(raw)
      memory_stats = required_section(raw, "memory_stats")
      required_number(memory_stats, "usage", parent: "memory_stats").to_i
    end

    def parse_memory_limit(raw)
      memory_stats = required_section(raw, "memory_stats")
      optional_number(memory_stats, "limit", parent: "memory_stats").to_i
    end

    def parse_memory_percent(raw)
      usage = parse_memory_usage(raw)
      limit = parse_memory_limit(raw)
      limit.positive? ? ((usage.to_f / limit) * 100.0).round(2) : 0.0
    end

    def parse_pids(raw)
      pids_stats = optional_section(raw, "pids_stats")
      return nil unless pids_stats

      pids = pids_stats["current"]
      pids.nil? ? nil : number(pids, "pids_stats.current").to_i
    end

    def required_section(raw, key, parent: nil)
      section = raw[key]
      return section if section.is_a?(Hash)

      raise InvalidStatsError, "docker stats #{section_name(parent, key)} must be a hash"
    end

    def optional_section(raw, key)
      return nil unless raw.key?(key)

      required_section(raw, key)
    end

    def required_number(section, key, parent:)
      return number(section[key], "#{parent}.#{key}") if section.key?(key)

      raise InvalidStatsError, "docker stats #{parent}.#{key} must be numeric"
    end

    def optional_number(section, key, parent:)
      return nil unless section.key?(key)

      number(section[key], "#{parent}.#{key}")
    end

    def number(value, name)
      return value if value.is_a?(Numeric) && value.finite?

      raise InvalidStatsError, "docker stats #{name} must be numeric"
    end

    def online_cpu_count(cpu_stats, cpu_usage)
      return number(cpu_stats["online_cpus"], "cpu_stats.online_cpus") if cpu_stats.key?("online_cpus")

      percpu_usage = cpu_usage["percpu_usage"]
      return 1 if percpu_usage.nil?
      return percpu_usage.length if percpu_usage.is_a?(Array) && percpu_usage.all? { |usage| valid_number?(usage) }

      raise InvalidStatsError, "docker stats cpu_stats.cpu_usage.percpu_usage must be an array of numbers"
    end

    def valid_number?(value)
      value.is_a?(Numeric) && value.finite?
    end

    def section_name(parent, key)
      [ parent, key ].compact.join(".")
    end

    # Updates peak/average summaries and increments container_metrics_count
    # in a single UPDATE, avoiding the extra write that counter_cache would
    # cause. Shared by both agent and service container metric collectors.
    def update_summaries(model_class:, id:, metric:)
      model_class.where(id: id).update_all(
        model_class.sanitize_sql_array(
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
  end
end
