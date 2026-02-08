# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    def execute(project_id:)
      project = Project.find(project_id)
      client = project.github_token.client

      labels = project.label_mappings.values.compact
      github_issues = client.issues(
        project.full_name,
        labels: labels,
        state: "open",
        per_page: 100
      )

      synced_issues = github_issues.map { |gi| sync_issue(project, gi) }

      logger.info(
        message: "github_sync.fetch_issues",
        project_id: project.id,
        issue_count: synced_issues.size
      )

      { issues: synced_issues, project_id: project_id }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end

    private

    def sync_issue(project, github_issue)
      issue = project.issues.find_or_initialize_by(github_issue_id: github_issue.id)
      issue.update!(
        github_number: github_issue.number,
        title: github_issue.title,
        body: github_issue.body,
        github_state: github_issue.state,
        labels: extract_labels(github_issue),
        github_created_at: github_issue.created_at,
        github_updated_at: github_issue.updated_at
      )

      { id: issue.id, github_number: issue.github_number, labels: issue.labels }
    end

    def extract_labels(github_issue)
      return [] unless github_issue.labels

      github_issue.labels.map { |l| l.respond_to?(:name) ? l.name : l.to_s }
    end
  end
end
