# frozen_string_literal: true

module Tools
  class SearchCode < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "search_code"

    def self.description
      "Search code across a project's knowledge base using semantic or keyword search."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to search within" },
          query: { type: "string", description: "The search query" },
          limit: { type: "integer", description: "Max results (default 10)", default: 10 }
        },
        required: %w[project_id query]
      }
    end

    def perform(project_id:, query:, limit: 10)
      project = project_for(project_id)

      search_limit = limit.to_i.clamp(1, 50)

      result = Knowledge::Search.call(
        project: project,
        query: query,
        mode: "hybrid",
        limit: search_limit
      )

      result[:results].map do |r|
        {
          id: r[:id],
          artifact_type: r[:artifact_type],
          name: r[:identifier],
          path: r[:scope_path],
          score: r[:score],
          content_preview: r[:content].to_s.truncate(500)
        }
      end
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
