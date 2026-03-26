# frozen_string_literal: true

module Knowledge
  class Search
    MODES = %w[exact semantic hybrid].freeze
    DEFAULT_MODE = "hybrid"
    DEFAULT_LIMIT = 20

    attr_reader :project, :query, :mode, :artifact_type, :limit

    def initialize(project:, query:, mode: DEFAULT_MODE, artifact_type: nil, limit: DEFAULT_LIMIT)
      @project = project
      @query = query
      @mode = MODES.include?(mode) ? mode : DEFAULT_MODE
      @artifact_type = artifact_type
      @limit = limit.present? ? [ limit.to_i, 1 ].max : DEFAULT_LIMIT
    end

    def self.call(...)
      new(...).call
    end

    def call
      start_time = monotonic_now

      results = case mode
      when "exact" then exact_search
      when "semantic" then semantic_search
      when "hybrid" then hybrid_search
      end

      elapsed = ((monotonic_now - start_time) * 1000).round

      {
        results: results.first(limit),
        meta: { mode: mode, total: results.size, took_ms: elapsed }
      }
    end

    private

    def exact_search
      artifacts = KnowledgeArtifact
        .active
        .for_project(project)

      artifacts = artifacts.by_type(artifact_type) if artifact_type.present?

      exact_matches = artifacts.where(identifier: query)

      if exact_matches.empty?
        exact_matches = artifacts.identifier_like(query)
      end

      exact_matches.includes(:knowledge_chunks, collector_run: :project_version)
        .flat_map { |artifact| format_artifact_results(artifact, source: "exact") }
    end

    def semantic_search
      chunks = KnowledgeChunk
        .active
        .for_project(project)
        .full_text_search(query)

      if artifact_type.present?
        chunks = chunks.joins(:knowledge_artifact)
          .where(knowledge_artifacts: { artifact_type: artifact_type })
      end

      chunks.includes(knowledge_artifact: { collector_run: :project_version })
        .limit(limit)
        .map { |chunk| format_chunk_result(chunk, source: "semantic") }
    end

    def hybrid_search
      exact_results = exact_search
      semantic_results = semantic_search

      seen_chunk_ids = Set.new
      merged = []

      exact_results.each do |result|
        seen_chunk_ids << result[:chunk_id]
        merged << result
      end

      semantic_results.each do |result|
        next if seen_chunk_ids.include?(result[:chunk_id])

        seen_chunk_ids << result[:chunk_id]
        merged << result
      end

      merged
    end

    def format_artifact_results(artifact, source:)
      version = artifact.collector_run&.project_version
      version_info = build_version_info(version)

      artifact.knowledge_chunks.active.ordered.map do |chunk|
        {
          chunk_id: chunk.id,
          artifact_type: artifact.artifact_type,
          identifier: artifact.identifier,
          content: chunk.content,
          score: 1.0,
          source: source,
          project_version: version_info
        }
      end
    end

    def format_chunk_result(chunk, source:)
      artifact = chunk.knowledge_artifact
      version = artifact.collector_run&.project_version

      {
        chunk_id: chunk.id,
        artifact_type: artifact.artifact_type,
        identifier: artifact.identifier,
        content: chunk.content,
        score: nil,
        source: source,
        project_version: build_version_info(version)
      }
    end

    def build_version_info(version)
      return {} unless version

      {
        commit_sha: version.commit_sha,
        committed_at: version.committed_at&.iso8601
      }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
