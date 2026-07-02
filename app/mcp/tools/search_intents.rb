# frozen_string_literal: true

module Tools
  class SearchIntents < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "search_intents"

    def self.description
      "Search change intent records (CIRs) within a project by directional query."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to search within" },
          query: { type: "string", description: "The CIR search query" },
          limit: { type: "integer", description: "Max results (default 10)", default: 10 }
        },
        required: %w[project_id query]
      }
    end

    def perform(project_id:, query:, limit: 10)
      project = project_for(project_id)
      normalized_query = query.to_s.strip
      raise ArgumentError, "query is required" if normalized_query.blank?

      search_scope(project, normalized_query)
        .limit(limit.to_i.clamp(1, 50))
        .map { |record| summarize(record) }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def search_scope(project, query)
      phrase_patterns = [ "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%" ]
      word_patterns = query.split(/\s+/).map(&:strip).reject(&:blank?).uniq.first(8).map do |term|
        "\\m#{Regexp.escape(term.downcase)}\\M"
      end
      text_sql = "LOWER(CONCAT_WS(' ', title, intent, behavior, constraints, decisions_made))"
      clauses = phrase_patterns.map { "#{text_sql} LIKE ?" }
      values = phrase_patterns.dup

      if word_patterns.any?
        clauses << word_patterns.map { "#{text_sql} ~* ?" }.join(" AND ")
        values.concat(word_patterns)
      end

      project.change_intents
        .where("(#{clauses.join(') OR (')})", *values)
        .order(Arel.sql(status_order_sql), created_at: :desc)
    end

    def status_order_sql
      <<~SQL.squish
        CASE change_intents.status
          WHEN 'active' THEN 0
          WHEN 'draft' THEN 1
          WHEN 'superseded' THEN 2
          ELSE 3
        END
      SQL
    end

    def summarize(record)
      {
        id: record.id,
        title: record.title,
        status: record.status,
        issue_id: record.issue_id,
        chat_session_id: record.chat_session_id,
        intent_preview: record.intent.to_s.truncate(200),
        constraints_preview: record.constraints.to_s.truncate(200),
        created_at: record.created_at,
        updated_at: record.updated_at
      }
    end
  end
end
