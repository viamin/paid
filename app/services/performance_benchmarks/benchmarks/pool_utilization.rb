# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    # Measures warm-container claim latency.
    #
    # Samples how long warmed pool entries sit idle before a run claims them.
    # Lower latency means the warm pool is being reused promptly instead of
    # holding idle capacity for long periods.
    class PoolUtilization
      KEY = "pool_utilization"
      WINDOW = 30.days
      LIMIT = 500

      def self.call(...)
        new(...).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        samples = ContainerPoolEntry
          .where(status: "claimed")
          .where(claimed_at: (now - WINDOW)..now)
          .where.not(warmed_at: nil, claimed_at: nil)
          .order(claimed_at: :desc)
          .limit(LIMIT)
          .pluck(:warmed_at, :claimed_at)
          .filter_map { |warmed_at, claimed_at| claim_latency_ms(warmed_at:, claimed_at:) }

        return skipped if samples.empty?

        Measurement.from_samples(
          key: KEY,
          samples: samples,
          metadata: metadata.merge(sample_count: samples.size)
        )
      end

      private

      attr_reader :now

      def claim_latency_ms(warmed_at:, claimed_at:)
        return if claimed_at < warmed_at

        ((claimed_at - warmed_at) * 1000).round(1)
      end

      def skipped
        Measurement.skipped(
          key: KEY,
          reason: "No claimed warm container entries found in the last 30 days.",
          metadata: metadata
        )
      end

      def metadata
        { window_days: 30, source: "container_pool_entries", sample_limit: LIMIT }
      end
    end
  end
end
