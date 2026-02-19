# frozen_string_literal: true

module SemanticSearch
  # Searches a project's indexed code chunks for content relevant to a query.
  # Supports both semantic search (via vector similarity) and full-text search
  # (via PostgreSQL full-text search).
  #
  # When embeddings are available, uses vector similarity for conceptual matching.
  # Falls back to PostgreSQL ILIKE for basic keyword matching.
  #
  # @example Semantic search
  #   results = SemanticSearch::Query.call(
  #     query: "authentication middleware",
  #     project: project,
  #     limit: 10
  #   )
  #
  # @example Full-text fallback
  #   results = SemanticSearch::Query.call(
  #     query: "def authenticate_user",
  #     project: project,
  #     mode: :text
  #   )
  class Query
    MODES = %i[semantic text auto].freeze
    DEFAULT_LIMIT = 10

    attr_reader :query, :project, :limit, :mode

    def initialize(query:, project:, limit: DEFAULT_LIMIT, mode: :auto)
      @query = query
      @project = project
      @limit = limit
      @mode = mode
    end

    def self.call(...)
      new(...).call
    end

    def call
      return CodeChunk.none if query.blank?

      case effective_mode
      when :semantic
        semantic_search
      else
        text_search
      end
    end

    private

    def effective_mode
      return mode if MODES.include?(mode) && mode != :auto

      # Auto mode: use semantic if embeddings exist, otherwise text
      if project.code_chunks.with_embeddings.exists?
        :semantic
      else
        :text
      end
    end

    def semantic_search
      embedding = generate_query_embedding(query)
      return text_search unless embedding

      project.code_chunks
        .search_by_embedding(embedding, limit: limit)
    end

    def text_search
      keywords = extract_keywords(query)
      return project.code_chunks.none if keywords.empty?

      conditions = keywords.map do |keyword|
        sanitized = "%#{CodeChunk.sanitize_sql_like(keyword)}%"
        CodeChunk.sanitize_sql_array(
          ["(content ILIKE ? OR file_path ILIKE ? OR identifier ILIKE ?)",
           sanitized, sanitized, sanitized]
        )
      end

      project.code_chunks
        .where(conditions.join(" OR "))
        .limit(limit)
    end

    def extract_keywords(text)
      text.to_s
        .split(/[\s,.\-_:;!?()#*]+/)
        .select { |word| word.length >= 3 }
        .uniq
        .first(10)
    end

    def generate_query_embedding(text)
      # Same embedding provider as GenerateEmbeddings.
      # Returns nil until an embedding provider is configured (see RDR-018).
      nil
    end
  end
end
