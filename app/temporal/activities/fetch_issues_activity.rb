# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    PAID_GENERATED_LABEL = "paid-generated"

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      client = project.github_token.client

      labels = project.label_mappings.values.compact_blank.uniq
      labels = (labels + [ PAID_GENERATED_LABEL ]).uniq
      github_issues = fetch_all_issues(client, project.full_name, labels)

      synced_issues = github_issues.map { |gi| sync_issue(project, gi) }
      closed_count = close_stale_issues(project, github_issues)

      logger.info(
        message: "github_sync.fetch_issues",
        project_id: project.id,
        issue_count: synced_issues.size,
        closed_count: closed_count
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

    # Fetches open issues for each label separately, then deduplicates.
    # GitHub's API treats multiple labels as AND (all required), so we
    # must query per-label to get OR behavior (any label matches).
    def fetch_all_issues(client, repo_full_name, labels)
      return fetch_issues_for_label(client, repo_full_name, nil) if labels.empty?

      seen_ids = Set.new
      all_issues = []

      labels.each do |label|
        fetch_issues_for_label(client, repo_full_name, label).each do |issue|
          next if seen_ids.include?(issue.id)

          seen_ids.add(issue.id)
          all_issues << issue
        end
      end

      all_issues
    end

    def fetch_issues_for_label(client, repo_full_name, label)
      issues = []
      page = 1

      loop do
        page_issues = client.issues(
          repo_full_name,
          labels: label ? [ label ] : nil,
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
            label: label,
            fetched_count: issues.size,
            max_pages: MAX_PAGES
          )
          break
        end
      end

      issues
    end

    def sync_issue(project, github_issue)
      creator_login = github_issue.user&.login || "unknown"
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

    def close_stale_issues(project, github_issues)
      return 0 if github_issues.empty?

      fetched_github_ids = github_issues.map(&:id).to_set
      stale_issues = project.issues.where(github_state: "open").where.not(github_issue_id: fetched_github_ids)
      count = stale_issues.count

      if count > 0
        stale_issues.update_all(github_state: "closed")

        logger.info(
          message: "github_sync.closed_stale_issues",
          project_id: project.id,
          count: count
        )
      end

      count
    end

    def extract_labels(github_issue)
      return [] unless github_issue.labels

      github_issue.labels.map { |l| l.respond_to?(:name) ? l.name : l.to_s }
    end
  end
end
