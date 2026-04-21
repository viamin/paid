# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    class WorkflowLatency
      KEY = "workflow_latency"
      WINDOW = 30.days
      LIMIT = 200

      def self.call(...)
        new(...).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        samples = AgentRun
          .finished
          .where.not(completed_at: nil)
          .where(created_at: (now - WINDOW)..now)
          .order(completed_at: :desc)
          .limit(LIMIT)
          .pluck(Arel.sql("EXTRACT(EPOCH FROM (completed_at - created_at)) * 1000"))
          .map(&:to_f)

        return skipped if samples.empty?

        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata)
      end

      private

      attr_reader :now

      def skipped
        Measurement.skipped(key: KEY, reason: "No completed agent runs found in the last 30 days.", metadata: metadata)
      end

      def metadata
        { window_days: 30, source: "agent_runs", sample_limit: LIMIT }
      end
    end
  end
end
