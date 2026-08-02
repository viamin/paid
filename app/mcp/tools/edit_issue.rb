# frozen_string_literal: true

module Tools
  class EditIssue < BaseTool
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
          }
        },
        required: %w[project_id issue_number]
      }
    end

    def perform(project_id:, issue_number:, title: nil, body: nil, state: nil, labels: nil, assignees: nil)
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
