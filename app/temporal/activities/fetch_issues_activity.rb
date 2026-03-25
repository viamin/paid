# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    PAID_GENERATED_LABEL = "paid-generated"
    PER_PAGE = 100

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      client = project.github_token.client

      labels = project.label_mappings.values.compact_blank.uniq
      labels = (labels + [ PAID_GENERATED_LABEL ]).uniq if labels.any?
      github_issues = fetch_all_issues(client, project.full_name, labels)

      synced_issues = github_issues.map { |gi| sync_issue(project, gi) }
      parse_dependencies(project, synced_issues) if synced_issues.any?
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
          per_page: PER_PAGE,
          page: page
        )

        break if page_issues.empty?

        issues.concat(page_issues)
        break if page_issues.size < PER_PAGE

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

    def parse_dependencies(project, synced_issues)
      synced_issue_ids = synced_issues.filter_map { |si| si[:id] }
      issues_relation = project.issues.where(
        id: synced_issue_ids,
        github_state: "open",
        is_pull_request: false
      )

      adjacency = IssueDependency.account_adjacency(project.account)

      issues_relation.find_each do |issue|
        Issues::ParseDependencies.call(issue: issue, adjacency: adjacency)
      rescue => e
        logger.warn(
          message: "github_sync.parse_dependencies_failed",
          project_id: project.id,
          issue_id: issue.id,
          github_number: issue.github_number,
          error_class: e.class.name,
          error: e.message
        )
      end

      synced_numbers = synced_issue_ids.any? ?
        project.issues.where(id: synced_issue_ids).pluck(:github_number) : []
      resolve_external_dependencies(project, synced_numbers)
    end

    def resolve_external_dependencies(project, synced_numbers)
      scope = IssueDependency
        .joins(issue: :project)
        .where(depends_on_issue_id: nil)
        .where(depends_on_owner: project.owner.downcase, depends_on_repo: project.repo.downcase)
        .where(projects: { account_id: project.account_id })

      # Only check external deps whose depends_on_number was synced in this run
      scope = scope.where(depends_on_number: synced_numbers) if synced_numbers.any?

      issues_by_number = project.issues
        .where(is_pull_request: false, github_number: scope.select(:depends_on_number))
        .index_by(&:github_number)

      scope.find_each do |dep|
        resolved_issue = issues_by_number[dep.depends_on_number]
        next unless resolved_issue

        if IssueDependency.exists?(issue_id: dep.issue_id, depends_on_issue_id: resolved_issue.id)
          dep.destroy!
          next
        end

        begin
          dep.update!(
            depends_on_issue: resolved_issue,
            depends_on_owner: nil,
            depends_on_repo: nil,
            depends_on_number: nil
          )
        rescue ActiveRecord::RecordNotUnique => e
          logger.warn(
            message: "github_sync.resolve_external_dependency_duplicate",
            project_id: project.id,
            dependency_id: dep.id,
            issue_id: dep.issue_id,
            depends_on_issue_id: resolved_issue.id,
            error_class: e.class.name,
            error: e.message
          )
          dep.destroy!
        end
      end
    rescue => e
      logger.warn(
        message: "github_sync.resolve_external_dependencies_failed",
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    def close_stale_issues(project, github_issues)
      fetched_github_ids = github_issues.map(&:id).to_set
      stale_issues = if fetched_github_ids.empty?
        project.issues.where(github_state: "open")
      else
        project.issues.where(github_state: "open").where.not(github_issue_id: fetched_github_ids)
      end
      count = stale_issues.count

      if count > 0
        stale_issues.update_all(github_state: "closed", updated_at: Time.current)

        # update_all bypasses ActiveRecord callbacks, so manually broadcast
        # the updated lists to remove closed items from connected browsers.
        project.broadcast_issues_update
        project.broadcast_pull_requests_update

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
