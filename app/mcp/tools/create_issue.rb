# frozen_string_literal: true

module Tools
  class CreateIssue < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "create_issue"
    def self.write_operation? = true

    def self.description
      "Create a new GitHub issue on a project. Returns the issue number and URL. " \
        "Use `Depends on owner/repo#N` in the body to declare cross-repo dependencies."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          title: { type: "string", description: "Issue title" },
          body: { type: "string", description: "Issue body (Markdown)", default: "" },
          labels: {
            type: "array",
            items: { type: "string" },
            description: "Label names to apply (must exist on the repo)"
          },
          assignees: {
            type: "array",
            items: { type: "string" },
            description: "GitHub usernames to assign"
          }
        },
        required: %w[project_id title]
      }
    end

    def perform(project_id:, title:, body: "", labels: [], assignees: [])
      project = project_for(project_id)
      client = require_github_client!(project)
      repo = project.full_name

      validate_labels!(client, repo, labels) if labels.any?

      issue = client.create_issue(repo, title:, body:, labels:, assignees: Array(assignees))

      Audit::RecordEvent.call(
        action: "issue.created",
        actor: user,
        subject: project,
        metadata: { issue_number: issue.number, title:, repo:, labels: }
      )

      { number: issue.number, url: issue.html_url }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def require_github_client!(project)
      client = project.github_token&.client
      raise ArgumentError, "Project has no GitHub token configured" unless client

      client
    end

    def validate_labels!(client, repo, requested_labels)
      available = label_cache(repo, client)
      unknown = requested_labels - available
      return if unknown.empty?

      raise ArgumentError, "Unknown labels: #{unknown.join(', ')}. Available: #{available.sort.join(', ')}"
    end

    def label_cache(repo, client)
      @label_cache ||= {}
      @label_cache[repo] ||= begin
        client.labels(repo).map { |l| l.is_a?(String) ? l : l.name }
      rescue StandardError => e
        Rails.logger.warn(message: "mcp.label_fetch_failed", repo:, error: e.message)
        []
      end
    end
  end
end
