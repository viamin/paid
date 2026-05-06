# frozen_string_literal: true

module Scaling
  # Automatically tunes worker pool configuration based on observed metrics.
  #
  # Analyzes recent scaling history and workload patterns to recommend
  # configuration adjustments. Works with WorkerPoolAdvisor to provide
  # adaptive scaling rather than static thresholds.
  #
  # @example
  #   tuner = Scaling::AutoTuner.new(
  #     current_config: Scaling::Configuration.new,
  #     history: recent_snapshots
  #   )
  #   recommendation = tuner.call
  #   recommendation[:adjustments]  # => { max_workers: 15, scale_up_step: 2 }
  class AutoTuner
    # Minimum history snapshots needed for meaningful analysis.
    MIN_HISTORY_SIZE = 10

    # Sustained high utilization threshold for recommending scale-up config changes.
    HIGH_UTILIZATION_RATIO = 0.7

    # Sustained low utilization threshold for recommending scale-down config changes.
    LOW_UTILIZATION_RATIO = 0.2

    # Queue depth growth rate that suggests step size increase.
    QUEUE_GROWTH_THRESHOLD = 2.0

    attr_reader :current_config, :history

    def initialize(current_config:, history:)
      @current_config = current_config
      @history = history
    end

    def self.call(...)
      new(...).call
    end

    def call
      return insufficient_data if history.size < MIN_HISTORY_SIZE

      adjustments = {}
      reasons = []

      analyze_utilization(adjustments, reasons)
      analyze_queue_growth(adjustments, reasons)
      analyze_scaling_headroom(adjustments, reasons)

      {
        status: adjustments.empty? ? :optimal : :adjustment_recommended,
        adjustments: adjustments,
        reasons: reasons,
        metrics: summary_metrics
      }
    end

    private

    def insufficient_data
      {
        status: :insufficient_data,
        adjustments: {},
        reasons: [ "Need at least #{MIN_HISTORY_SIZE} snapshots, have #{history.size}" ],
        metrics: {}
      }
    end

    def analyze_utilization(adjustments, reasons)
      avg_util = average_utilization
      high_util_ratio = history.count { |s| s.utilization > current_config.scale_up_utilization }.to_f / history.size

      if high_util_ratio > HIGH_UTILIZATION_RATIO
        new_max = [ current_config.max_workers + current_config.scale_up_step, 20 ].min
        if new_max > current_config.max_workers
          adjustments[:max_workers] = new_max
          reasons << "Sustained high utilization (#{format("%.0f", high_util_ratio * 100)}% of samples above threshold). " \
                     "Recommend increasing max_workers from #{current_config.max_workers} to #{new_max}."
        end
      elsif avg_util < current_config.scale_down_utilization && high_util_ratio < LOW_UTILIZATION_RATIO
        new_max = [ current_config.max_workers - 1, current_config.min_workers ].max
        if new_max < current_config.max_workers
          adjustments[:max_workers] = new_max
          reasons << "Consistently low utilization (avg #{format("%.1f", avg_util * 100)}%). " \
                     "Recommend decreasing max_workers from #{current_config.max_workers} to #{new_max}."
        end
      end
    end

    def analyze_queue_growth(adjustments, reasons)
      return if history.size < 3

      recent = history.last(5)
      depths = recent.map(&:queue_depth)
      return if depths.first.zero?

      growth_rate = depths.last.to_f / depths.first
      if growth_rate > QUEUE_GROWTH_THRESHOLD
        new_step = [ current_config.scale_up_step + 1, 5 ].min
        if new_step > current_config.scale_up_step
          adjustments[:scale_up_step] = new_step
          reasons << "Queue depth growing rapidly (#{format("%.1f", growth_rate)}x in recent window). " \
                     "Recommend increasing scale_up_step from #{current_config.scale_up_step} to #{new_step}."
        end
      end
    end

    def analyze_scaling_headroom(adjustments, reasons)
      at_max_ratio = history.count { |s| s.active_workers >= current_config.max_workers }.to_f / history.size
      return unless at_max_ratio > HIGH_UTILIZATION_RATIO

      still_queued = history.any? { |s| s.queue_depth > 0 && s.active_workers >= current_config.max_workers }
      return unless still_queued

      reasons << "Workers frequently at max capacity (#{format("%.0f", at_max_ratio * 100)}% of samples) with pending queue. " \
                 "Consider increasing max_workers or reviewing job throughput."
    end

    def average_utilization
      return 0.0 if history.empty?

      history.sum(&:utilization) / history.size
    end

    def summary_metrics
      return {} if history.empty?

      {
        avg_utilization: average_utilization.round(3),
        avg_queue_depth: (history.sum(&:queue_depth).to_f / history.size).round(1),
        max_queue_depth: history.map(&:queue_depth).max,
        avg_active_workers: (history.sum(&:active_workers).to_f / history.size).round(1),
        sample_count: history.size
      }
    end
  end
end
