# frozen_string_literal: true

module Tools
  class CreateIssue < BaseTool
    include GithubIssueToolSupport

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
          },
          confirmed: {
            type: "boolean",
            description: "Must be true to execute this write operation"
          }
        },
        required: %w[project_id title confirmed]
      }
    end

    # @spec CHAT-TOOL-CONFIRMATION-001
    def perform(project_id:, title:, confirmed: false, body: "", labels: [], assignees: [])
      raise ArgumentError, "Confirmation required: set confirmed=true to create an issue" unless confirmed

      project = project_for(project_id)
      client = require_github_client!(project)
      repo = project.full_name

      validate_labels!(client, repo, labels) if labels.any?

      issue = client.create_issue(repo, title:, body:, labels:, assignees: Array(assignees))
      sync_local_issue!(project, issue)

      Audit::RecordEvent.call(
        action: "issue.created",
        actor: user,
        subject: project,
        metadata: { issue_number: issue.number, title:, repo:, labels: }
      )

      { number: issue.number, url: issue.html_url }
    end

    private

    def sync_local_issue!(project, github_issue)
      issue = Issues::UpsertFromGithub.call(project:, github_issue:)
      Issues::ParseDependencies.call(issue:)
      issue
    end
  end
end
