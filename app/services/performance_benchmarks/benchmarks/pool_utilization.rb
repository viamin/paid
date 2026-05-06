# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    # Measures container pool utilization efficiency.
    #
    # Calculates the ratio of pool hits (warm container claims) to total
    # container provisions over a recent window. Higher utilization means
    # the pool is effectively reducing cold starts.
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
        claimed = ContainerPoolEntry
          .where(status: "claimed")
          .where(claimed_at: (now - WINDOW)..now)
          .count

        total_provisions = AgentRunPhase
          .where(phase_key: "provision_container", status: "completed")
          .where(started_at: (now - WINDOW)..now)
          .count

        return skipped if total_provisions.zero?

        hit_rate = (claimed.to_f / total_provisions * 100).round(1)
        samples = [ hit_rate ]

        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata.merge(
          claimed_count: claimed,
          total_provisions: total_provisions
        ))
      end

      private

      attr_reader :now

      def skipped
        Measurement.skipped(
          key: KEY,
          reason: "No container provisions found in the last 30 days.",
          metadata: metadata
        )
      end

      def metadata
        { window_days: 30, source: "container_pool_entries" }
      end
    end
  end
end
