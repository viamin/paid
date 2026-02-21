# frozen_string_literal: true

module SemanticSearch
  # Queries indexed code chunks for a project using semantic similarity
  # or full-text search.
  #
  # Semantic search requires embeddings to be generated for both the query
  # and the stored code chunks. Full-text search uses PostgreSQL's built-in
  # text search capabilities as a fallback.
  #
  # @example Semantic search (requires embeddings)
  #   results = SemanticSearch::Query.call(
  #     query: "authentication middleware",
  #     project: project,
  #     embedding: query_embedding
  #   )
  #
  # @example Full-text search (no embeddings needed)
  #   results = SemanticSearch::Query.call(
  #     query: "authenticate_user",
  #     project: project,
  #     mode: :text
  #   )
  class Query
    MODES = %i[semantic text hybrid].freeze
    DEFAULT_LIMIT = 10

    attr_reader :query, :project, :mode, :limit, :embedding

    def initialize(query:, project:, mode: :text, limit: DEFAULT_LIMIT, embedding: nil)
      @query = query
      @project = project
      @mode = mode
      @limit = limit
      @embedding = embedding
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      results = case mode
      when :semantic
        semantic_search
      when :text
        text_search
      when :hybrid
        hybrid_search
      end

      results.limit(limit)
    end

    private

    def validate!
      raise ArgumentError, "Unknown search mode: #{mode}" unless MODES.include?(mode)
      raise ArgumentError, "Semantic search requires an embedding vector" if mode == :semantic && embedding.nil?
    end

    def semantic_search
      project.code_chunks
        .with_embedding
        .nearest_neighbors(:embedding, embedding, distance: :cosine)
    end

    def text_search
      search_terms = query.split(/\s+/).map { |term| term.gsub(/[^a-zA-Z0-9_.]/, "") }.reject(&:blank?)
      return project.code_chunks.none if search_terms.empty?

      scope = project.code_chunks
      search_terms.each do |term|
        scope = scope.where("content ILIKE ?", "%#{CodeChunk.sanitize_sql_like(term)}%")
      end
      scope.order(:file_path, :start_line)
    end

    def hybrid_search
      if embedding.present?
        # Combine semantic and text results, preferring semantic matches
        semantic_ids = semantic_search.limit(limit).pluck(:id)
        text_ids = text_search.limit(limit).pluck(:id)
        combined_ids = (semantic_ids + text_ids).uniq.first(limit)
        CodeChunk.where(id: combined_ids)
      else
        text_search
      end
    end
  end
end
