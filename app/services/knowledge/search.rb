# frozen_string_literal: true

module Knowledge
  class Search
    MODES = %w[exact semantic hybrid].freeze
    DEFAULT_MODE = "hybrid"
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    attr_reader :project, :query, :mode, :artifact_type, :version, :limit, :api_key

    def initialize(project:, query:, mode: DEFAULT_MODE, artifact_type: nil, version: nil, limit: DEFAULT_LIMIT, api_key: nil)
      @project = project
      @query = query
      @mode = MODES.include?(mode) ? mode : DEFAULT_MODE
      @artifact_type = artifact_type
      @version = version
      @limit = limit.present? ? [ limit.to_i, 1 ].max.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT
      @api_key = api_key
    end

    def self.call(...)
      new(...).call
    end

    def call
      start_time = monotonic_now

      search_output = perform_search
      results = strip_internal_fields(search_output[:results].first(limit))
      elapsed = ((monotonic_now - start_time) * 1000).round

      {
        results: results,
        meta: build_meta(search_output, elapsed)
      }
    end

    private

    def perform_search
      case mode
      when "exact"
        exact_results = Search::Exact.call(
          project: project, query: query,
          artifact_type: artifact_type, limit: limit
        )
        { results: exact_results, exact_count: exact_results.size, semantic_count: 0 }
      when "semantic"
        semantic_results = Search::Semantic.call(
          project: project, query: query,
          artifact_type: artifact_type, limit: limit, api_key: api_key
        )
        { results: semantic_results, exact_count: 0, semantic_count: semantic_results.size }
      when "hybrid"
        Search::Hybrid.call(
          project: project, query: query,
          artifact_type: artifact_type, version: version, limit: limit, api_key: api_key
        )
      end
    end

    def build_meta(search_output, elapsed)
      {
        mode: mode,
        total: search_output[:results].first(limit).size,
        took_ms: elapsed,
        exact_count: search_output[:exact_count],
        semantic_count: search_output[:semantic_count]
      }
    end

    def strip_internal_fields(results)
      results.map do |result|
        result.except(:status, :link_count, :created_at)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
