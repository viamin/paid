# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      client = project.github_token.client

      labels = project.label_mappings.values.compact_blank.uniq
      github_issues = fetch_all_issues(client, project.full_name, labels)

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

    MAX_PAGES = 10

    def fetch_all_issues(client, repo_full_name, labels)
      issues = []
      page = 1

      loop do
        page_issues = client.issues(
          repo_full_name,
          labels: labels,
          state: "open",
          per_page: 100,
          page: page
        )

        break if page_issues.empty?

        issues.concat(page_issues)
        break if page_issues.size < 100

        page += 1

        if page > MAX_PAGES
          logger.warn(
            message: "github_sync.fetch_issues_page_limit",
            repo: repo_full_name,
            fetched_count: issues.size,
            max_pages: MAX_PAGES
          )
          break
        end
      end

      issues
    end

    def sync_issue(project, github_issue)
      creator_login = github_issue.user&.login
      trusted = project.trusted_github_user?(creator_login)

      unless trusted
        logger.warn(
          message: "github_sync.untrusted_issue_skipped",
          project_id: project.id,
          github_number: github_issue.number,
          creator: creator_login
        )
      end

      issue = project.issues.find_or_initialize_by(github_issue_id: github_issue.id)
      issue.update!(
        github_number: github_issue.number,
        title: github_issue.title,
        body: trusted ? github_issue.body : nil,
        github_creator_login: creator_login,
        github_state: github_issue.state,
        labels: extract_labels(github_issue),
        is_pull_request: github_issue.pull_request.present?,
        github_created_at: github_issue.created_at,
        github_updated_at: github_issue.updated_at
      )

      { id: issue.id, github_number: issue.github_number, labels: issue.labels, trusted: trusted }
    end

    def extract_labels(github_issue)
      return [] unless github_issue.labels

      github_issue.labels.map { |l| l.respond_to?(:name) ? l.name : l.to_s }
    end
  end
end
