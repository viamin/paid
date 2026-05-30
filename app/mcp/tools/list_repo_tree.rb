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
      client = resolve_client(project)

      ref = project.default_branch if ref == "HEAD"
      ref ||= "main"

      if path.present?
        entries = directory_entries(client, project, path, ref)
      else
        entries = tree_entries(client, project, ref)
      end

      {
        path: path.presence || "/",
        ref: ref,
        entries: entries.first(MAX_ENTRIES),
        truncated: entries.size > MAX_ENTRIES,
        identity: identity_label(project)
      }
    rescue GithubClient::NotFoundError
      { error: "Path not found: #{path}", identity: identity_label(project) }
    end

    private

    def resolve_client(project)
      client = project.client
      raise ArgumentError, "Project has no GitHub credentials configured" unless client

      client
    end

    def directory_entries(client, project, path, ref)
      data = client.contents(project.full_name, path: path, ref: ref)
      return [] unless data.is_a?(Array)

      data.map do |entry|
        { name: entry.name, path: entry.path, type: entry.type, size: entry.size }
      end
    end

    def tree_entries(client, project, ref)
      result = client.tree(project.full_name, ref, recursive: true)
      return [] unless result&.tree

      result.tree.map do |entry|
        { name: File.basename(entry.path), path: entry.path, type: entry.type, size: entry.size }
      end
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
