# frozen_string_literal: true

module Scaling
  # Immutable configuration for the worker pool scaling algorithm.
  #
  # All thresholds and limits are tunable per-pool. Sensible defaults target
  # a single-machine deployment where cost and latency are balanced.
  #
  # @example
  #   config = Scaling::Configuration.new(max_workers: 20, cost_per_worker_hour_cents: 50)
  #   config.max_workers  # => 20
  class Configuration
    DEFAULTS = {
      min_workers: 1,
      max_workers: 10,

      # Queue-depth thresholds (jobs per active worker).
      scale_up_queue_ratio: 5.0,
      scale_down_queue_ratio: 0.5,

      # Utilization thresholds (0.0–1.0).
      scale_up_utilization: 0.85,
      scale_down_utilization: 0.30,

      # Cooldown between consecutive scaling actions (seconds).
      cooldown_period: 120,

      # Cost constraints (cents per hour).
      cost_per_worker_hour_cents: 0,
      max_hourly_cost_cents: 0,

      # How many workers to add/remove per scaling step.
      scale_up_step: 1,
      scale_down_step: 1
    }.freeze

    VALID_KEYS = DEFAULTS.keys.freeze

    attr_reader(*VALID_KEYS)

    def initialize(**overrides)
      unknown = overrides.keys - VALID_KEYS
      raise ArgumentError, "Unknown configuration keys: #{unknown.join(", ")}" if unknown.any?

      merged = DEFAULTS.merge(overrides)
      VALID_KEYS.each { |key| instance_variable_set(:"@#{key}", merged[key]) }

      validate!
      freeze
    end

    def to_h
      VALID_KEYS.each_with_object({}) { |key, hash| hash[key] = public_send(key) }
    end

    private

    def validate!
      raise ArgumentError, "min_workers must be >= 0" if min_workers.negative?
      raise ArgumentError, "max_workers must be >= min_workers" if max_workers < min_workers
      raise ArgumentError, "scale_up_queue_ratio must be positive" unless scale_up_queue_ratio.positive?
      raise ArgumentError, "scale_down_queue_ratio must be non-negative" if scale_down_queue_ratio.negative?
      raise ArgumentError, "scale_down_queue_ratio must be < scale_up_queue_ratio" if scale_down_queue_ratio >= scale_up_queue_ratio
      raise ArgumentError, "scale_up_utilization must be in 0.0..1.0" unless (0.0..1.0).cover?(scale_up_utilization)
      raise ArgumentError, "scale_down_utilization must be in 0.0..1.0" unless (0.0..1.0).cover?(scale_down_utilization)
      raise ArgumentError, "scale_down_utilization must be < scale_up_utilization" if scale_down_utilization >= scale_up_utilization
      raise ArgumentError, "cooldown_period must be non-negative" if cooldown_period.negative?
      raise ArgumentError, "scale_up_step must be positive" unless scale_up_step.positive?
      raise ArgumentError, "scale_down_step must be positive" unless scale_down_step.positive?
      raise ArgumentError, "cost_per_worker_hour_cents must be non-negative" if cost_per_worker_hour_cents.negative?
      raise ArgumentError, "max_hourly_cost_cents must be non-negative" if max_hourly_cost_cents.negative?
    end
  end
end
