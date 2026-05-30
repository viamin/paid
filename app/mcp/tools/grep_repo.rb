# frozen_string_literal: true

module Tools
  class GrepRepo < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    MAX_RESULTS = 30

    def self.tool_name = "grep_repo"

    def self.description
      "Search for a string or pattern across a project's GitHub repository using GitHub code search."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          query: { type: "string", description: "Search query (string or regex pattern)" },
          path_filter: { type: "string", description: "Optional path prefix to narrow search scope (e.g. 'app/models')" }
        },
        required: %w[project_id query]
      }
    end

    def perform(project_id:, query:, path_filter: nil)
      project = project_for(project_id)
      client = resolve_client(project)

      qualified_query = build_query(project.full_name, query, path_filter)

      result = client.search_code(qualified_query, per_page: MAX_RESULTS)

      matches = (result&.items || []).map do |item|
        {
          path: item.path,
          name: item.name,
          html_url: item.html_url
        }
      end

      {
        total_count: result&.total_count || 0,
        matches: matches,
        truncated: (result&.total_count || 0) > MAX_RESULTS,
        identity: identity_label(project)
      }
    rescue GithubClient::NotFoundError
      { matches: [], total_count: 0, identity: identity_label(project) }
    end

    private

    def resolve_client(project)
      client = project.client
      raise ArgumentError, "Project has no GitHub credentials configured" unless client

      client
    end

    def build_query(repo_full_name, query, path_filter)
      parts = [ "repo:#{repo_full_name}", query ]
      parts << "path:#{path_filter}" if path_filter.present?
      parts.join(" ")
    end

    def identity_label(project)
      if project.github_installation.present?
        "github-app:#{project.github_installation.github_installation_id}"
      elsif project.github_token.present?
        "project-token:#{project.github_token.name}"
      else
        "unknown"
      end
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
