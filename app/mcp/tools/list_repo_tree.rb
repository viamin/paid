# frozen_string_literal: true

module Tools
  class ListRepoTree < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    MAX_ENTRIES = 1000

    def self.tool_name = "list_repo_tree"

    def self.description
      "List files and directories in a project's GitHub repository at a given path."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          path: { type: "string", description: "Directory path within the repository. Defaults to root.", default: "" },
          ref: { type: "string", description: "Git ref (branch, tag, or SHA). Defaults to HEAD.", default: "HEAD" }
        },
        required: %w[project_id]
      }
    end

    def perform(project_id:, path: "", ref: "HEAD")
      project = project_for(project_id)
      repo_client = resolve_repo_read_client(project)
      client = repo_client.client

      ref = project.default_branch if ref == "HEAD"
      ref ||= "main"

      entries = directory_entries(client, project, path, ref)

      {
        path: path.presence || "/",
        ref: ref,
        entries: entries.first(MAX_ENTRIES),
        truncated: entries.size > MAX_ENTRIES,
        identity: repo_client.identity
      }
    rescue GithubClient::NotFoundError
      { error: "Path not found: #{path}", identity: repo_client.identity }
    end

    private

    def directory_entries(client, project, path, ref)
      data = client.contents(project.full_name, path: path, ref: ref)
      raise GithubClient::NotFoundError, "Path is not a directory" unless data.is_a?(Array)

      data.map do |entry|
        { name: entry.name, path: entry.path, type: entry.type, size: entry.size }
      end
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
