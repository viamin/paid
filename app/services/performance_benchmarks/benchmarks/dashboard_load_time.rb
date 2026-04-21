# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    class DashboardLoadTime
      KEY = "dashboard_load_time"
      ITERATIONS = 5

      def self.call(...)
        new(...).call
      end

      def initialize(account: Account.order(:id).first)
        @account = account
      end

      def call
        return skipped if account.nil?

        samples = ITERATIONS.times.map { measure_dashboard }
        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata)
      end

      private

      attr_reader :account

      def measure_dashboard
        monotonic_ms do
          Dashboard::Stats.call(account: account)
          Knowledge::DashboardStats.call(account: account)
          Dashboard::LiveStats.call(account: account)
          Scaling::QueueMonitor.call(account: account)
          AgentRun.joins(:project).where(projects: { account_id: account.id }).active.limit(20).load
          Dashboard::RecentActivity.call(account: account)
        end
      end

      def skipped
        Measurement.skipped(key: KEY, reason: "No account exists to benchmark dashboard service calls.", metadata: metadata)
      end

      def metadata
        { iterations: ITERATIONS, source: "dashboard_service_calls", account_id: account&.id }
      end

      def monotonic_ms
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      end
    end
  end
end
