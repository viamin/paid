# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    # Measures database query performance by analyzing slow query frequency.
    #
    # Samples recent agent run phase queries to gauge overall database
    # responsiveness. Reports the average query duration as the primary metric.
    class QueryPerformance
      KEY = "query_performance"
      WINDOW = 7.days
      LIMIT = 100
      PHASE_KEYS = %w[provision_execution_environment provision_container run_agent create_pull_request].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        samples = collect_samples
        return skipped if samples.empty?

        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata)
      end

      private

      attr_reader :now

      def collect_samples
        AgentRunPhase
          .where(phase_key: PHASE_KEYS)
          .where(status: "completed")
          .where(started_at: (now - WINDOW)..now)
          .order(started_at: :desc)
          .limit(LIMIT)
          .pluck(:duration_seconds)
          .map { |seconds| seconds.to_f * 1000 }
      end

      def skipped
        Measurement.skipped(
          key: KEY,
          reason: "No completed agent run phases found in the last 7 days.",
          metadata: metadata
        )
      end

      def metadata
        { window_days: 7, source: "agent_run_phases", sample_limit: LIMIT }
      end
    end
  end
end
