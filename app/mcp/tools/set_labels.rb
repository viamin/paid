# frozen_string_literal: true

module Tools
  class SetLabels < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "set_labels"
    def self.write_operation? = true

    def self.description
      "Replace all labels on a GitHub issue or pull request. Computes the add/remove " \
        "diff from the current labels — pass the full desired label set."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_number: { type: "integer", description: "The GitHub issue or PR number" },
          labels: {
            type: "array",
            items: { type: "string" },
            description: "Complete desired label set"
          }
        },
        required: %w[project_id issue_number labels]
      }
    end

    def perform(project_id:, issue_number:, labels:)
      project = project_for(project_id)
      client = require_github_client!(project)
      repo = project.full_name

      validate_labels!(client, repo, labels)

      current = client.issue(repo, issue_number)
      current_labels = extract_label_names(current.labels)

      to_add = labels - current_labels
      to_remove = current_labels - labels

      client.add_labels_to_issue(repo, issue_number, to_add) if to_add.any?

      removed = []
      failed = []
      to_remove.each do |label|
        client.remove_label_from_issue(repo, issue_number, label)
        removed << label
      rescue GithubClient::Error => e
        failed << { label:, error: e.message }
      end

      refreshed_issue = client.issue(repo, issue_number)
      final_labels = extract_label_names(refreshed_issue.labels)
      sync_local_issue!(project, refreshed_issue)

      Audit::RecordEvent.call(
        action: "issue.labels_changed",
        actor: user,
        subject: project,
        metadata: {
          issue_number:, repo:, added: to_add, removed:, failed:
        }
      )

      {
        added: to_add,
        removed:,
        failed:,
        current_labels: final_labels
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

    def sync_local_issue!(project, github_issue)
      Issues::UpsertFromGithub.call(project:, github_issue:)
    end

    def extract_label_names(labels)
      labels.map { |l| l.is_a?(String) ? l : l.name }
    end

    def validate_labels!(client, repo, requested_labels)
      available = label_cache(repo, client)
      unknown = requested_labels - available
      return if unknown.empty?

      raise ArgumentError, "Unknown labels: #{unknown.join(', ')}. Available: #{available.sort.join(', ')}"
    end

    def label_cache(repo, client)
      @label_cache ||= {}
      @label_cache[repo] ||= client.labels(repo).map { |l| l.is_a?(String) ? l : l.name }
    end
  end
end
