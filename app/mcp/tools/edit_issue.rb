# frozen_string_literal: true

module Tools
  class EditIssue < BaseTool
    include GithubIssueToolSupport

    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "edit_issue"
    def self.write_operation? = true

    def self.description
      "Update an existing GitHub issue. Pass only the fields you want to change. " \
        "For body edits, the caller should read the current issue body first " \
        "(via get_issue_details), apply the desired changes, and pass the complete " \
        "new body — this is a full replacement, not a patch."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_number: { type: "integer", description: "The GitHub issue number" },
          title: { type: "string", description: "New title (omit to keep current)" },
          body: { type: "string", description: "New body in full — read first, modify, then pass the complete replacement" },
          state: { type: "string", description: "New state", enum: %w[open closed] },
          labels: {
            type: "array",
            items: { type: "string" },
            description: "New labels (replaces all existing labels)"
          },
          assignees: {
            type: "array",
            items: { type: "string" },
            description: "New assignees (replaces all existing)"
          },
          confirmed: {
            type: "boolean",
            description: "Must be true to execute this write operation"
          }
        },
        required: %w[project_id issue_number confirmed]
      }
    end

    # @spec CHAT-TOOL-CONFIRMATION-001
    def perform(project_id:, issue_number:, confirmed: false, title: nil, body: nil, state: nil, labels: nil, assignees: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to edit an issue" unless confirmed

      project = project_for(project_id)
      client = require_github_client!(project)
      repo = project.full_name

      options = {}
      options[:title] = title if title
      options[:body] = body if body
      options[:state] = state if state
      options[:labels] = labels if labels
      options[:assignees] = assignees if assignees

      raise ArgumentError, "No fields to update" if options.empty?

      if labels
        validate_labels!(client, repo, labels)
      end

      issue = client.update_issue(repo, issue_number, **options)
      sync_local_issue!(project, issue, parse_dependencies: options.key?(:body))

      Audit::RecordEvent.call(
        action: "issue.updated",
        actor: user,
        subject: project,
        metadata: { issue_number:, repo:, changes: options.keys }
      )

      {
        number: issue.number,
        url: issue.html_url,
        title: issue.title,
        state: issue.state
      }
    end

    private

    def sync_local_issue!(project, github_issue, parse_dependencies: false)
      issue = Issues::UpsertFromGithub.call(project:, github_issue:)
      Issues::ParseDependencies.call(issue:) if parse_dependencies
      issue
    end
  end
end
