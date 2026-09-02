# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    class ContainerStartupTime
      KEY = "container_startup_time"
      WINDOW = 30.days
      LIMIT = 200

      def self.call(...)
        new(...).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        samples = AgentRunPhase
          .where(phase_key: %w[provision_execution_environment provision_container], status: "completed")
          .where(started_at: (now - WINDOW)..now)
          .order(started_at: :desc)
          .limit(LIMIT)
          .pluck(:duration_seconds)
          .map { |seconds| seconds.to_f * 1000 }

        return skipped if samples.empty?

        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata)
      end

      private

      attr_reader :now

      def skipped
        Measurement.skipped(
          key: KEY,
          reason: "No completed execution-environment provisioning phases found in the last 30 days.",
          metadata: metadata
        )
      end

      def metadata
        { window_days: 30, source: "agent_run_phases", sample_limit: LIMIT }
      end
    end
  end
end
