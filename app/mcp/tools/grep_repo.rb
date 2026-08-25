# frozen_string_literal: true

module Tools
  class GrepRepo < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    MAX_RESULTS = 30
    SEARCH_QUALIFIER_PATTERN = /
      (?:\A|\s)\K
      (?:repo|org|user|path|language|filename|extension|symbol|content):\S+
    /ix

    def self.tool_name = "grep_repo"

    # @spec CHAT-API-012
    def self.description
      "Search for a string or pattern across a project's GitHub repository using GitHub code search. " \
        "Rate-limit sensitive: prefer search_code (knowledge base) first; use grep_repo only when " \
        "knowledge search is unavailable or stale, or when exact GitHub code search behavior is needed."
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
      repo_client = resolve_repo_read_client(project)
      client = repo_client.client

      qualified_query = build_query(project.full_name, query, path_filter)
      return empty_result(repo_client.identity) if qualified_query.strip == "repo:#{project.full_name}"

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
        identity: repo_client.identity
      }
    rescue GithubClient::NotFoundError
      empty_result(repo_client.identity)
    end

    private

    def empty_result(identity)
      { matches: [], total_count: 0, identity: identity }
    end

    def build_query(repo_full_name, query, path_filter)
      sanitized_query = sanitize_query(query)
      parts = [ "repo:#{repo_full_name}" ]
      parts << sanitized_query if sanitized_query.present?
      sanitized_path_filter = sanitize_path_filter(path_filter)
      parts << "path:#{sanitized_path_filter}" if sanitized_path_filter.present?
      parts.join(" ")
    end

    def sanitize_query(query)
      query.gsub(SEARCH_QUALIFIER_PATTERN, "").squish
    end

    def sanitize_path_filter(path_filter)
      path_filter.to_s.gsub(SEARCH_QUALIFIER_PATTERN, "").squish.split.first
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
