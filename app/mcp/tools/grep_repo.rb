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

    def self.description
      "Search for a string or pattern across a project's GitHub repository using GitHub code search."
    end

    # Demotes this tool to a fallback once the session's project has a ready
    # knowledge base, so the model prefers the knowledge-backed `search_code`
    # for ordinary code discovery instead of burning shared GitHub Code
    # Search rate limits on every lookup (#3392).
    def self.description_for(session:)
      return description unless knowledge_ready?(session)

      "#{description} Fallback only: the project's knowledge base is ready, so prefer " \
        "search_code for ordinary code discovery. Use grep_repo only when GitHub code " \
        "search is specifically needed, e.g. content not indexed in the knowledge base."
    end

    def self.knowledge_ready?(session)
      session&.project&.knowledge_status == "ready"
    end
    private_class_method :knowledge_ready?

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
