# frozen_string_literal: true

module Knowledge
  class Search
    MODES = %w[exact semantic hybrid].freeze
    DEFAULT_MODE = "hybrid"
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    attr_reader :project, :query, :mode, :artifact_type, :version, :limit, :api_key, :api_base_url, :agent_run_id

    def initialize(project:, query:, mode: DEFAULT_MODE, artifact_type: nil, version: nil, limit: DEFAULT_LIMIT, api_key: nil, api_base_url: nil, agent_run_id: nil)
      @project = project
      @query = query
      @mode = MODES.include?(mode) ? mode : DEFAULT_MODE
      @artifact_type = artifact_type
      @version = version
      @limit = limit.present? ? [ limit.to_i, 1 ].max.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT
      @api_key = api_key
      @api_base_url = api_base_url
      @agent_run_id = agent_run_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      start_time = monotonic_now

      search_output = perform_search
      results = strip_internal_fields(search_output[:results].first(limit))
      record_usage(results)
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
          artifact_type: artifact_type, limit: limit, api_key: api_key, api_base_url: api_base_url
        )
        { results: semantic_results, exact_count: 0, semantic_count: semantic_results.size }
      when "hybrid"
        Search::Hybrid.call(
          project: project, query: query,
          artifact_type: artifact_type, version: version, limit: limit, api_key: api_key, api_base_url: api_base_url
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

    def record_usage(results)
      return if tracking_agent_run.blank?

      timestamp = Time.current
      rows = results.group_by { |result| result[:artifact_type] }.map do |artifact_type, grouped|
        {
          agent_run_id: tracking_agent_run.id,
          project_id: project.id,
          artifact_type: artifact_type,
          goal: tracking_agent_run.goal,
          context_type: "search",
          artifact_count: grouped.map { |result| result[:artifact_id] }.uniq.count,
          chunk_count: grouped.count,
          created_at: timestamp,
          updated_at: timestamp
        }
      end
      return if rows.empty?

      KnowledgeUsageStat.upsert_all(
        rows,
        unique_by: :idx_knowledge_usage_stats_unique,
        on_duplicate: Arel.sql(
          "project_id = EXCLUDED.project_id, " \
            "goal = EXCLUDED.goal, " \
            "artifact_count = knowledge_usage_stats.artifact_count + EXCLUDED.artifact_count, " \
            "chunk_count = knowledge_usage_stats.chunk_count + EXCLUDED.chunk_count, " \
            "updated_at = EXCLUDED.updated_at"
        )
      )
    end

    def tracking_agent_run
      @tracking_agent_run ||= agent_run_id.present? ? AgentRun.select(:id, :goal).find_by(id: agent_run_id) : nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
