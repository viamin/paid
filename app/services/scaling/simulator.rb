# frozen_string_literal: true

module Scaling
  # Replays a sequence of metrics snapshots through the scaling algorithm
  # and records each decision. Useful for back-testing configuration
  # against historical or synthetic workload data.
  #
  # @example
  #   config = Scaling::Configuration.new(max_workers: 8, cooldown_period: 60)
  #   snapshots = [
  #     Scaling::MetricsSnapshot.new(queue_depth: 2, active_workers: 2, busy_workers: 1, timestamp: t),
  #     Scaling::MetricsSnapshot.new(queue_depth: 15, active_workers: 2, busy_workers: 2, timestamp: t + 60),
  #     ...
  #   ]
  #   result = Scaling::Simulator.call(snapshots: snapshots, config: config)
  #   result.decisions.size           # => number of snapshots evaluated
  #   result.scale_up_count           # => how many scale-ups occurred
  #   result.peak_workers             # => highest worker count reached
  #   result.total_cost_cents         # => estimated cost over the simulation
  class Simulator
    Result = Struct.new(
      :decisions, :scale_up_count, :scale_down_count, :hold_count,
      :peak_workers, :min_workers_seen, :total_cost_cents, :max_queue_depth,
      keyword_init: true
    )

    attr_reader :snapshots, :config, :initial_workers

    def initialize(snapshots:, config: Configuration.new, initial_workers: nil)
      @snapshots = snapshots
      @config = config
      @initial_workers = initial_workers || config.min_workers
    end

    def self.call(...)
      new(...).call
    end

    def call
      decisions = []
      current_workers = initial_workers
      last_scaled_at = nil
      history = []

      snapshots.each do |snap|
        # Rewrite the snapshot with the simulated worker count so the
        # advisor sees the pool size that would actually exist.
        simulated = MetricsSnapshot.new(
          queue_depth: snap.queue_depth,
          active_workers: current_workers,
          busy_workers: [ snap.busy_workers, current_workers ].min,
          timestamp: snap.timestamp
        )

        decision = WorkerPoolAdvisor.call(
          snapshot: simulated,
          config: config,
          last_scaled_at: last_scaled_at,
          history: history
        )

        decisions << decision

        if decision.action != :hold
          current_workers = decision.target_workers
          last_scaled_at = snap.timestamp
        end

        history << simulated
      end

      build_result(decisions)
    end

    private

    def build_result(decisions)
      targets = decisions.map(&:target_workers)
      cost = compute_cost(decisions)

      Result.new(
        decisions: decisions,
        scale_up_count: decisions.count { |d| d.action == :scale_up },
        scale_down_count: decisions.count { |d| d.action == :scale_down },
        hold_count: decisions.count { |d| d.action == :hold },
        peak_workers: targets.max || initial_workers,
        min_workers_seen: targets.min || initial_workers,
        total_cost_cents: cost,
        max_queue_depth: snapshots.map(&:queue_depth).max || 0
      )
    end

    # Estimates cost by computing worker-hours between consecutive snapshots.
    def compute_cost(decisions)
      return 0 if config.cost_per_worker_hour_cents.zero?
      return 0 if decisions.size < 2

      total_cents = 0
      decisions.each_cons(2) do |prev, curr|
        elapsed_hours = (curr.metrics[:timestamp] - prev.metrics[:timestamp]) / 3600.0
        total_cents += (prev.target_workers * config.cost_per_worker_hour_cents * elapsed_hours).ceil
      end
      total_cents
    end
  end
end
