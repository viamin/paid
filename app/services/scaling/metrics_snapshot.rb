# frozen_string_literal: true

module Scaling
  # Point-in-time metrics for a worker pool, used as input to the scaling
  # algorithm. All fields are plain numbers — no ActiveRecord dependencies —
  # so the algorithm can be tested without a database.
  #
  # @example
  #   snap = Scaling::MetricsSnapshot.new(
  #     queue_depth: 12,
  #     active_workers: 3,
  #     busy_workers: 2,
  #     timestamp: Time.current
  #   )
  class MetricsSnapshot
    attr_reader :queue_depth, :active_workers, :busy_workers, :timestamp

    def initialize(queue_depth:, active_workers:, busy_workers:, timestamp: Time.current)
      @queue_depth = Integer(queue_depth)
      @active_workers = Integer(active_workers)
      @busy_workers = Integer(busy_workers)
      @timestamp = timestamp

      validate!
      freeze
    end

    # Jobs waiting per active worker. Returns Float::INFINITY when there
    # are queued jobs but zero workers (signals immediate scale-up).
    def queue_ratio
      return 0.0 if queue_depth.zero?
      return Float::INFINITY if active_workers.zero?

      queue_depth.to_f / active_workers
    end

    # Fraction of active workers currently busy (0.0–1.0).
    # Returns 0.0 when no workers are active.
    def utilization
      return 0.0 if active_workers.zero?

      busy_workers.to_f / active_workers
    end

    def to_h
      { queue_depth: queue_depth, active_workers: active_workers,
        busy_workers: busy_workers, utilization: utilization,
        queue_ratio: queue_ratio, timestamp: timestamp }
    end

    private

    def validate!
      raise ArgumentError, "queue_depth must be non-negative" if queue_depth.negative?
      raise ArgumentError, "active_workers must be non-negative" if active_workers.negative?
      raise ArgumentError, "busy_workers must be non-negative" if busy_workers.negative?
      raise ArgumentError, "busy_workers cannot exceed active_workers" if busy_workers > active_workers
    end
  end
end
