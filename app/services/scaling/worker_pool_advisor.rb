# frozen_string_literal: true

module Scaling
  # Pure-function scaling advisor for worker pools. Given a metrics snapshot
  # and configuration, it returns a scaling decision without side effects.
  #
  # The algorithm is a hybrid reactive/predictive approach:
  #
  # 1. **Reactive layer** — evaluates current queue depth and utilization
  #    against configured thresholds to decide scale-up or scale-down.
  # 2. **Predictive layer** (optional) — when a history of snapshots is
  #    provided, detects a rising queue trend and pre-scales before
  #    thresholds are breached.
  # 3. **Constraints** — cost caps, cooldown periods, and min/max bounds
  #    are enforced after the raw decision is made.
  #
  # @example Basic usage
  #   config  = Scaling::Configuration.new(max_workers: 10)
  #   snap    = Scaling::MetricsSnapshot.new(queue_depth: 30, active_workers: 3, busy_workers: 3)
  #   result  = Scaling::WorkerPoolAdvisor.call(snapshot: snap, config: config)
  #   result.action        # => :scale_up
  #   result.target_workers # => 4
  #
  # @example With cooldown enforcement
  #   result = Scaling::WorkerPoolAdvisor.call(
  #     snapshot: snap,
  #     config: config,
  #     last_scaled_at: 30.seconds.ago
  #   )
  #   result.action  # => :hold (cooldown not elapsed)
  class WorkerPoolAdvisor
    Decision = Struct.new(:action, :target_workers, :reason, :metrics, keyword_init: true)

    ACTIONS = %i[scale_up scale_down hold].freeze

    # Minimum number of recent snapshots required for trend detection.
    TREND_WINDOW_MIN = 3

    attr_reader :snapshot, :config, :last_scaled_at, :history

    def initialize(snapshot:, config: Configuration.new, last_scaled_at: nil, history: [])
      @snapshot = snapshot
      @config = config
      @last_scaled_at = last_scaled_at
      @history = history
    end

    def self.call(...)
      new(...).call
    end

    def call
      return cooldown_decision if in_cooldown?

      raw = compute_raw_decision
      constrained = apply_constraints(raw)
      build_decision(constrained[:action], constrained[:target], constrained[:reason])
    end

    private

    # --- Cooldown ---

    def in_cooldown?
      return false unless last_scaled_at

      elapsed = snapshot.timestamp - last_scaled_at
      elapsed < config.cooldown_period
    end

    def cooldown_decision
      remaining = (config.cooldown_period - (snapshot.timestamp - last_scaled_at)).ceil
      build_decision(:hold, snapshot.active_workers, "cooldown active (#{remaining}s remaining)")
    end

    # --- Raw decision (before constraints) ---

    def compute_raw_decision # @spec WORKER-POOL-SCALING-003
      # Priority 1: scale up if queue is deep or utilization is high
      if scale_up_needed?
        target = snapshot.active_workers + config.scale_up_step
        return { action: :scale_up, target: target, reason: scale_up_reason }
      end

      # Priority 2: predictive scale-up from trend detection
      if trend_indicates_scale_up?
        target = snapshot.active_workers + config.scale_up_step
        return { action: :scale_up, target: target, reason: "queue trend rising — pre-scaling" }
      end

      # Priority 3: scale down if both queue and utilization are low
      if scale_down_needed?
        target = snapshot.active_workers - config.scale_down_step
        return { action: :scale_down, target: target, reason: scale_down_reason }
      end

      { action: :hold, target: snapshot.active_workers, reason: "metrics within thresholds" }
    end

    def scale_up_needed?
      snapshot.queue_ratio > config.scale_up_queue_ratio ||
        snapshot.utilization > config.scale_up_utilization
    end

    def scale_up_reason
      parts = []
      parts << "queue_ratio=#{format_number(snapshot.queue_ratio)} > #{format_number(config.scale_up_queue_ratio)}" if snapshot.queue_ratio > config.scale_up_queue_ratio
      parts << "utilization=#{format_number(snapshot.utilization)} > #{format_number(config.scale_up_utilization)}" if snapshot.utilization > config.scale_up_utilization
      parts.join("; ")
    end

    def scale_down_needed?
      return false if snapshot.active_workers <= config.min_workers

      snapshot.queue_ratio < config.scale_down_queue_ratio &&
        snapshot.utilization < config.scale_down_utilization
    end

    def scale_down_reason
      "queue_ratio=#{format_number(snapshot.queue_ratio)} < #{format_number(config.scale_down_queue_ratio)}; " \
        "utilization=#{format_number(snapshot.utilization)} < #{format_number(config.scale_down_utilization)}"
    end

    # --- Predictive trend detection ---

    # Returns true when recent queue depth shows a consistently rising trend
    # that will likely breach the scale-up threshold soon.
    def trend_indicates_scale_up? # @spec WORKER-POOL-SCALING-004
      return false if history.size < TREND_WINDOW_MIN
      return false if scale_up_needed? # already reactive

      recent = history.last(TREND_WINDOW_MIN + 1).map(&:queue_depth)
      return false if recent.size < TREND_WINDOW_MIN

      # Check if queue depth is monotonically increasing
      increasing = recent.each_cons(2).all? { |a, b| b > a }
      return false unless increasing

      # Project the next value and check if it would breach the threshold
      projected_depth = recent.last + (recent.last - recent.first)
      projected_ratio = snapshot.active_workers.positive? ? projected_depth.to_f / snapshot.active_workers : Float::INFINITY
      projected_ratio > config.scale_up_queue_ratio
    end

    # --- Constraints ---

    def apply_constraints(raw) # @spec WORKER-POOL-SCALING-005
      target = raw[:target]
      action = raw[:action]
      reason = raw[:reason]

      # Clamp to min/max bounds
      target = target.clamp(config.min_workers, config.max_workers)

      # Enforce cost cap
      if config.cost_per_worker_hour_cents.positive? && config.max_hourly_cost_cents.positive?
        max_affordable = (config.max_hourly_cost_cents / config.cost_per_worker_hour_cents.to_f).floor
        if target > max_affordable
          target = max_affordable
          reason = "#{reason} (capped by cost limit: max #{max_affordable} workers at " \
                   "#{config.cost_per_worker_hour_cents}¢/worker/hr)"
        end
      end

      # If constraints neutralized the change, convert to hold
      if target == snapshot.active_workers && action != :hold
        action = :hold
        reason = "#{reason} (constrained to current count)"
      end

      { action: action, target: target, reason: reason }
    end

    # --- Helpers ---

    def build_decision(action, target, reason)
      Decision.new(
        action: action,
        target_workers: target,
        reason: reason,
        metrics: snapshot.to_h
      )
    end

    def format_number(value)
      return "∞" if value == Float::INFINITY

      value == value.to_i ? value.to_i.to_s : format("%.2f", value)
    end
  end
end
