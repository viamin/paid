# frozen_string_literal: true

module PerformanceBenchmarks
  module Benchmarks
    class SearchLatency
      KEY = "search_latency"
      ITERATIONS = 10

      def self.call(...)
        new(...).call
      end

      def initialize(project: nil, query: nil, mode: "exact")
        @project = project || default_project
        @query = query
        @mode = mode
      end

      def call
        return skipped("No project exists to benchmark knowledge search.") if project.nil?

        benchmark_query = query.presence || default_query
        if benchmark_query.blank?
          return skipped("No active knowledge artifact exists to provide a repeatable search query.")
        end

        samples = ITERATIONS.times.map { measure_search(benchmark_query) }
        Measurement.from_samples(key: KEY, samples: samples, metadata: metadata(benchmark_query))
      end

      private

      attr_reader :project, :query, :mode

      def default_project
        Project
          .joins(:knowledge_artifacts)
          .merge(KnowledgeArtifact.active.where.not(identifier: [ nil, "" ]))
          .order(:id)
          .first || Project.order(:id).first
      end

      def default_query
        KnowledgeArtifact.active
          .for_project(project)
          .where.not(identifier: [ nil, "" ])
          .order(:id)
          .pick(:identifier)
      end

      def measure_search(benchmark_query)
        monotonic_ms do
          Knowledge::Search.call(project: project, query: benchmark_query, mode: mode, limit: 20)
        end
      end

      def skipped(reason)
        Measurement.skipped(key: KEY, reason: reason, metadata: metadata(query))
      end

      def metadata(benchmark_query)
        {
          iterations: ITERATIONS,
          source: "knowledge_search",
          mode: mode,
          project_id: project&.id,
          query: benchmark_query
        }
      end

      def monotonic_ms
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      end
    end
  end
end
