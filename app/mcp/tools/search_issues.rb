# frozen_string_literal: true

module Tools
  # Searches a project's GitHub issues for likely duplicates before filing new
  # ones. Backed by GitHub's issue search API (Octokit's +search_issues+),
  # scoped to the project's repository. The +query+ argument is a thin
  # pass-through to GitHub's issue search syntax (`in:title,body`, `label:`,
  # `author:`, etc.) — see https://docs.github.com/search-github/searching-on-github/searching-issues-and-pull-requests
  class SearchIssues < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    DEFAULT_RESULTS = 30
    MAX_RESULTS = 100
    SCOPE_QUALIFIER_PATTERN = /(?:\A|\s)\K(?:repo|org|user):\S+/i

    def self.tool_name = "search_issues"

    def self.description
      "Search a project's GitHub issues for likely duplicates before filing new ones. " \
        "The query is a thin pass-through to GitHub's issue search syntax " \
        "(e.g. `in:title,body`, `label:bug`, `author:someone`); results are always scoped " \
        "to the project's repository and to issues (not pull requests)."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          query: { type: "string", description: "Search text, passed through to GitHub issue search syntax" },
          state: { type: "string", description: "Filter by GitHub issue state", enum: %w[open closed all] },
          labels: { type: "array", items: { type: "string" }, description: "Label names to filter by" },
          limit: { type: "integer", description: "Max results (default #{DEFAULT_RESULTS}, max #{MAX_RESULTS})", default: DEFAULT_RESULTS }
        },
        required: %w[project_id query]
      }
    end

    def perform(project_id:, query:, state: nil, labels: nil, limit: DEFAULT_RESULTS)
      project = project_for(project_id)
      repo_client = resolve_repo_read_client(project)
      search_limit = limit.to_i.clamp(1, MAX_RESULTS)

      qualified_query = build_query(project.full_name, query, state:, labels:)
      result = repo_client.client.search_issues(qualified_query, per_page: search_limit)

      {
        total_count: result&.total_count || 0,
        issues: (result&.items || []).map { |item| serialize(item) },
        truncated: (result&.total_count || 0) > search_limit,
        identity: repo_client.identity
      }
    end

    private

    def build_query(repo_full_name, query, state:, labels:)
      parts = [ "repo:#{repo_full_name}", "is:issue" ]
      parts << "state:#{state}" if state.present? && state != "all"
      Array(labels).each { |label| parts << %(label:"#{label}") }
      sanitized_query = sanitize_query(query)
      parts << sanitized_query if sanitized_query.present?
      parts.join(" ")
    end

    def sanitize_query(query)
      query.to_s.gsub(SCOPE_QUALIFIER_PATTERN, "").squish
    end

    def serialize(item)
      {
        github_number: item.number,
        title: item.title,
        github_state: item.state,
        labels: Array(item.labels).map { |label| label.respond_to?(:name) ? label.name : label["name"] },
        html_url: item.html_url,
        created_at: item.created_at,
        updated_at: item.updated_at
      }
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
