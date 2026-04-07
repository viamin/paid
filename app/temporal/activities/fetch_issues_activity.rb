# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    DEFAULT_PER_PAGE = 100

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      client = project.github_token.client
      incremental = project.last_issue_sync_at.present?
      sync_started_at = Time.current

      github_issues, truncated = fetch_all_issues(client, project.full_name, since: project.last_issue_sync_at)

      synced_issues = github_issues.map { |gi| sync_issue(project, gi) }
      parse_issue_relationships(project, synced_issues) if synced_issues.any?
      closed_count = close_stale_issues(project, github_issues, truncated: truncated, incremental: incremental)

      # Only advance the watermark when the fetch was not truncated. A truncated
      # fetch means issues beyond the page cap were not retrieved; advancing the
      # watermark would permanently skip them on future syncs.
      project.touch_last_issue_sync_at(sync_started_at) unless truncated

      # Exclude closed issues from downstream processing (DetectLabelsActivity).
      # sync_issue already persisted their github_state to the DB, but passing
      # them downstream could incorrectly trigger agent runs for closed work.
      open_issues = synced_issues.reject { |si| si[:github_state] == "closed" }

      logger.info(
        message: "github_sync.fetch_issues",
        project_id: project.id,
        issue_count: synced_issues.size,
        closed_count: closed_count,
        incremental: incremental
      )

      { issues: open_issues, project_id: project_id }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end

    private

    DEFAULT_MAX_PAGES = 10

    # Fetches all open GitHub issues and pull requests for visibility.
    # Trigger eligibility is decided later by DetectLabelsActivity.
    # Sorts by recently-updated so that newly-labeled issues appear first
    # even when the page cap is reached in busy repos.
    # Returns [issues, truncated] where truncated is true if the
    # DEFAULT_MAX_PAGES cap was reached before all pages were fetched.
    def fetch_all_issues(client, repo_full_name, since: nil)
      fetch_issues_for_label(client, repo_full_name, nil, sort: :updated, since: since)
    end

    # Returns [issues, truncated] where truncated is true when the
    # DEFAULT_MAX_PAGES cap was reached before all pages were fetched.
    def fetch_issues_for_label(client, repo_full_name, label, sort: nil, since: nil)
      issues = []
      page = 1
      truncated = false

      loop do
        opts = {
          labels: label ? [ label ] : nil,
          state: "open",
          per_page: DEFAULT_PER_PAGE,
          page: page
        }
        opts[:sort] = sort if sort
        if since
          opts[:since] = since.iso8601
          # Incremental fetches must request all states so that issues closed
          # on GitHub since the last sync are captured and their local
          # github_state is updated via sync_issue.
          opts[:state] = "all"
        end

        page_issues = client.issues(repo_full_name, **opts)

        break if page_issues.empty?

        issues.concat(page_issues)
        break if page_issues.size < DEFAULT_PER_PAGE

        page += 1

        if page > DEFAULT_MAX_PAGES
          # Probe the next page to distinguish a genuinely truncated result set
          # from one that exactly fills DEFAULT_MAX_PAGES * DEFAULT_PER_PAGE.
          # Without this check a false truncation prevents the watermark from
          # ever advancing, causing the same window to be re-fetched indefinitely.
          probe_opts = opts.merge(page: page, per_page: 1)
          if client.issues(repo_full_name, **probe_opts).any?
            truncated = true
            logger.warn(
              message: "github_sync.fetch_issues_page_limit",
              repo: repo_full_name,
              label: label,
              fetched_count: issues.size,
              max_pages: DEFAULT_MAX_PAGES
            )
          end
          break
        end
      end

      [ issues, truncated ]
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

      { id: issue.id, github_number: issue.github_number, labels: issue.labels,
        github_state: issue.github_state, trusted: trusted }
    end

    # TODO(#430): Fetching comments per issue is an N+1 API call pattern that
    # increases sync time and rate-limit pressure. Consider skipping unchanged
    # issues (via github_updated_at) or batching comment fetches.
    def parse_issue_relationships(project, synced_issues)
      synced_issue_ids = synced_issues.filter_map { |si| si[:id] }
      issues_relation = project.issues.where(
        id: synced_issue_ids,
        github_state: "open",
        is_pull_request: false
      )

      client = project.github_token.client

      # Compute adjacency once before the loop for cycle detection. Within this
      # sync batch, deps created by earlier iterations won't be visible for cycle
      # detection until the next full sync — an acceptable trade-off vs N×DB reads.
      adjacency = IssueDependency.account_adjacency(project.account)
      parent_child_changed = false

      issues_relation.find_each do |issue|
        comment_bodies = fetch_trusted_comment_bodies(client, project, issue)
        # nil means comment fetch failed — skip ALL parsing for this issue to
        # avoid stale-removal of comment-derived deps. Body-only parsing would
        # delete previously-persisted comment deps that are still valid.
        next if comment_bodies.nil?

        Issues::ParseDependencies.call(issue: issue, adjacency: adjacency, comments: comment_bodies)
        parent_child_changed |= Issues::ParseParentChild.call(issue: issue, comments: comment_bodies)
      rescue GithubClient::RateLimitError
        raise
      rescue => e
        logger.warn(
          message: "github_sync.parse_issue_relationships_failed",
          project_id: project.id,
          issue_id: issue.id,
          github_number: issue.github_number,
          error_class: e.class.name,
          error: e.message
        )
      end

      # ParseParentChild returns true only when sync_children changed rows
      # via update_all (which bypasses callbacks). sync_parent uses update!
      # and triggers its own after_update_commit broadcasts, so we only need
      # a manual broadcast for the update_all path.
      project.broadcast_issues_update if parent_child_changed

      synced_numbers = synced_issues.filter_map { |si| si[:github_number] }
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

    # Returns trusted comment bodies, or nil if comments could not be fetched.
    # Returning nil (vs empty array) lets callers distinguish "no comments" from
    # "fetch failed", avoiding accidental deletion of comment-derived dependencies.
    def fetch_trusted_comment_bodies(client, project, issue)
      github_comments = client.issue_comments(project.full_name, issue.github_number)
      # Sort by created_at to guarantee chronological processing regardless
      # of API response ordering. ParseDependencies relies on comment order
      # to resolve "latest directive wins" semantics.
      github_comments
        .sort_by { |c| c.created_at || Time.at(0) }
        .select { |c| project.trusted_github_user?(c.user&.login) }
        .map { |c| c.body.to_s }
    rescue GithubClient::RateLimitError
      raise
    rescue => e
      logger.warn(
        message: "github_sync.fetch_comments_failed",
        project_id: project.id,
        issue_id: issue.id,
        github_number: issue.github_number,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def close_stale_issues(project, github_issues, truncated: false, incremental: false)
      # When the fetch was truncated by the DEFAULT_MAX_PAGES cap, the fetched list
      # is not an authoritative snapshot. Closing issues not in this list
      # would incorrectly close still-open GitHub issues that were beyond
      # the page limit. Skip stale-closure entirely in this case.
      #
      # Incremental fetches (with `since`) only return recently-updated issues,
      # not all open issues, so the result set is not exhaustive. However, any
      # issue whose state changed to closed on GitHub will appear in the
      # incremental results (because closing updates `updated_at`), so
      # sync_issue will set its github_state to "closed" via the normal path.
      # Skip the bulk stale-closure pass to avoid false positives.
      if truncated || incremental
        reason = truncated ? "fetch_truncated" : "incremental_fetch"
        logger.warn(
          message: "github_sync.stale_closure_skipped",
          project_id: project.id,
          reason: reason
        )
        return 0
      end

      fetched_github_ids = github_issues.map(&:id).to_set
      # Only close stale issues that were directly fetched from the GitHub
      # issues API. Synthetic issues (e.g. from code scanning alerts)
      # are intentionally excluded from this stale-closure pass and are
      # reconciled by ScanSecurityAlertsActivity instead.
      github_sourced = project.issues.where(github_state: "open", source: Issue::GITHUB_SOURCE)
      stale_issues = if fetched_github_ids.empty?
        github_sourced
      else
        github_sourced.where.not(github_issue_id: fetched_github_ids)
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
