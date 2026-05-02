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

      unless GithubHealthState.github_available?
        logger.info(
          message: "fetch_issues.skipped_github_circuit_open",
          project_id: project_id
        )
        return { issues: [], project_id: project_id, github_circuit_open: true }
      end

      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      client = project.github_token.client
      incremental = project.last_issue_sync_at.present?
      sync_started_at = Time.current

      github_issues, truncated = fetch_all_issues(client, project.full_name, since: project.last_issue_sync_at)

      synced_issues = github_issues.map { |gi| sync_issue(project, gi) }
      parse_issue_relationships(project, synced_issues) if synced_issues.any?
      enhance_issue_rechecks = detect_enhance_issue_rechecks(project, synced_issues)
      closed_count = close_stale_issues(project, github_issues, truncated: truncated, incremental: incremental)
      stale_pr_count = reconcile_open_pull_requests(project, client) if incremental && !truncated

      if truncated && incremental
        # Incremental fetches sort ascending (oldest-updated first), so a
        # truncated result contains the oldest slice of the `since` window.
        # Advance the watermark to the latest `updated_at` among fetched
        # issues so the next sync picks up where this one left off.
        #
        # Prefer subtracting 1 second for an inclusive boundary: GitHub's
        # `since` filters as "updated after" the given timestamp, so
        # issues sharing the exact second-level `updated_at` would be
        # excluded on the next poll. Overlapping is safe (sync_issue is
        # idempotent).
        #
        # However, if subtracting 1 second would not advance past the
        # current watermark (i.e. all fetched issues share the same
        # `updated_at` second as the watermark), use the exact timestamp
        # to guarantee forward progress. Some same-second issues may be
        # skipped, but permanent re-fetch of the same window is worse.
        latest_updated = github_issues.filter_map(&:updated_at).max
        if latest_updated
          inclusive_cursor = latest_updated - 1.second
          # `incremental` is only true when `last_issue_sync_at` is present,
          # so the nil-guard is unnecessary here.
          new_watermark = if inclusive_cursor <= project.last_issue_sync_at
            latest_updated
          else
            inclusive_cursor
          end
          project.touch_last_issue_sync_at(new_watermark)
        end
      elsif !truncated
        # Subtract 1 second to create an inclusive boundary: GitHub's
        # `since` filter is strictly `updated_at > X`, so any issue whose
        # `updated_at` equals the watermark exactly would be excluded on
        # the next poll. The small overlap is harmless because sync_issue
        # is idempotent (upsert by github_issue_id).
        project.touch_last_issue_sync_at(sync_started_at - 1.second)
      end

      recheck_issue_ids = enhance_issue_rechecks.map { |recheck| recheck[:issue_id] }.to_set

      # Exclude closed issues and enhance_issue waits/rechecks from downstream
      # processing (DetectLabelsActivity). Rechecks are returned separately for
      # the workflow to queue, and needs-input issues are still waiting on
      # human answers, so evaluating their automation labels in this poll can
      # incorrectly start a create_pr run before enhancement completes.
      # sync_issue already persisted their github_state to the DB, but passing
      # them downstream could incorrectly trigger agent runs for closed work.
      # Note: parse_issue_relationships receives all synced_issues (including
      # closed), but filters to github_state: "open" internally.
      open_issues = synced_issues.reject do |si|
        si[:github_state] == "closed" ||
          recheck_issue_ids.include?(si[:id]) ||
          enhance_issue_needs_input?(project, si)
      end

      # During incremental fetches, issues whose `updated_at` did not change
      # on GitHub are not returned by the API. However, those issues may still
      # need re-evaluation by DetectLabelsActivity — for example when a
      # blocking dependency was resolved, or project label/trust settings
      # changed. Append locally-open issues in re-scannable states that were
      # not already part of this fetch so the workflow passes them downstream.
      if incremental && !truncated
        fetched_ids = open_issues.map { |si| si[:id] }.to_set
        rescannable = project.issues
          .where(github_state: "open", paid_state: %w[new needs_input recommend_close analyzed])
          .where.not("labels @> ?::jsonb", [ project.enhance_issue_needs_input_label_name ].to_json)
          .where.not(id: fetched_ids.to_a)
          .limit(200)
          .pluck(:id, :github_number, :github_state)

        rescannable.each do |id, github_number, github_state|
          open_issues << { id: id, github_number: github_number, labels: [],
                           github_state: github_state, rescan: true }
        end
      end

      logger.info(
        message: "github_sync.fetch_issues",
        project_id: project.id,
        issue_count: synced_issues.size,
        closed_count: closed_count,
        stale_pr_count: stale_pr_count || 0,
        incremental: incremental,
        enhance_issue_recheck_count: enhance_issue_rechecks.size,
        rescan_count: incremental ? open_issues.count { |si| si[:rescan] } : 0
      )

      { issues: open_issues, project_id: project_id, enhance_issue_rechecks: enhance_issue_rechecks }
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
    #
    # Full fetches sort descending (newest-updated first) so that
    # newly-labeled issues appear first even when the page cap is reached.
    #
    # Incremental fetches sort ascending (oldest-updated first) so that
    # a truncated result set still makes forward progress — the watermark
    # can be advanced to the latest `updated_at` among the fetched issues
    # instead of stalling at the same `since` window indefinitely.
    #
    # Returns [issues, truncated] where truncated is true if the
    # DEFAULT_MAX_PAGES cap was reached before all pages were fetched.
    def fetch_all_issues(client, repo_full_name, since: nil)
      direction = since ? :asc : :desc
      fetch_issues_for_label(client, repo_full_name, nil, sort: :updated, direction: direction, since: since)
    end

    # Returns [issues, truncated] where truncated is true when the
    # DEFAULT_MAX_PAGES cap was reached before all pages were fetched.
    def fetch_issues_for_label(client, repo_full_name, label, sort: nil, direction: nil, since: nil)
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
        opts[:direction] = direction if direction
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
          #
          # Only probe during incremental fetches where false truncation matters
          # for watermark advancement. For full fetches, false truncation just
          # means stale-closure is conservatively skipped — already safe — so
          # skip the extra API call to avoid unnecessary rate-limit pressure.
          if since
            # `page` was already incremented to DEFAULT_MAX_PAGES + 1 on
            # line above, so this probes the next page beyond the cap.
            probe_opts = opts.merge(page: page)
            truncated = client.issues(repo_full_name, **probe_opts).any?
          else
            truncated = true
          end

          if truncated
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
      existing_issue = project.issues.find_by(github_issue_id: github_issue.id)
      previous_labels = Array(existing_issue&.labels)

      unless trusted
        logger.warn(
          message: "github_sync.untrusted_issue_skipped",
          project_id: project.id,
          github_number: github_issue.number,
          creator: creator_login
        )
      end

      issue = Issues::UpsertFromGithub.call(
        project: project,
        github_issue: github_issue,
        body: trusted ? github_issue.body : nil
      )

      { id: issue.id, github_number: issue.github_number, labels: issue.labels,
        github_state: issue.github_state, trusted: trusted, removed_labels: previous_labels - issue.labels }
    end

    def detect_enhance_issue_rechecks(project, synced_issues)
      label = project.enhance_issue_needs_input_label_name
      synced_issues.filter_map do |issue_data|
        next unless Array(issue_data[:removed_labels]).include?(label)

        issue = project.issues.find(issue_data[:id])
        next if issue.is_pull_request? || issue.github_state == "closed" || issue.paid_state != "needs_input"

        enqueue_enhance_issue_recheck(project, issue)
      end
    end

    def enhance_issue_needs_input?(project, issue_data)
      Array(issue_data[:labels]).include?(project.enhance_issue_needs_input_label_name)
    end

    def enqueue_enhance_issue_recheck(project, issue)
      max_rounds = project.max_enhance_issue_reevaluation_rounds
      limit_reached = false

      issue.with_lock do
        if issue.enhance_issue_rounds >= max_rounds
          limit_reached = true
        else
          issue.update!(enhance_issue_rounds: issue.enhance_issue_rounds + 1, paid_state: "in_progress")
        end
      end

      return stop_enhance_issue_recheck(project, issue, max_rounds) if limit_reached

      logger.info(
        message: "agent_execution.enhance_issue_recheck_requested",
        project_id: project.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        enhance_issue_rounds: issue.enhance_issue_rounds,
        max_rounds: max_rounds
      )

      { issue_id: issue.id, issue_number: issue.github_number, enhance_issue_rounds: issue.enhance_issue_rounds }
    end

    def stop_enhance_issue_recheck(project, issue, max_rounds)
      post_enhance_issue_limit_comment(project, issue, max_rounds)
      issue.update!(paid_state: "completed")

      logger.info(
        message: "agent_execution.enhance_issue_recheck_limit_reached",
        project_id: project.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        enhance_issue_rounds: issue.enhance_issue_rounds,
        max_rounds: max_rounds
      )
      nil
    rescue GithubClient::Error
      restore_enhance_issue_recheck_signal(project, issue)
      raise
    end

    def post_enhance_issue_limit_comment(project, issue, max_rounds)
      project.github_token.client.add_comment(
        project.full_name,
        issue.github_number,
        <<~COMMENT
          ## Auto-enhancement stopped

          Paid has reached the configured limit of #{max_rounds} enhancement re-evaluation rounds for this issue.

          Manual review is needed before enhancement can continue.
        COMMENT
      )
    end

    def restore_enhance_issue_recheck_signal(project, issue)
      issue.with_lock do
        issue.update!(
          labels: Array(issue.labels) | [ project.enhance_issue_needs_input_label_name ],
          paid_state: "needs_input"
        )
      end
    end

    # Parses dependency and parent/child relationships from issue comments.
    # Re-parses issues whose github_updated_at has advanced beyond their last
    # successful parse, as well as issues never parsed or whose previous parse
    # failed — relationships_parsed_at is only bumped on success, so transient
    # fetch errors naturally retry on the next sync. Trust-policy changes clear
    # relationships_parsed_at on the project's issues to force reparse (see
    # Project#invalidate_relationship_parsing_on_trust_change).
    def parse_issue_relationships(project, synced_issues)
      synced_issue_ids = synced_issues.filter_map { |si| si[:id] }

      issues_relation = project.issues
        .where(id: synced_issue_ids, github_state: "open", is_pull_request: false)
        .where("relationships_parsed_at IS NULL OR relationships_parsed_at < github_updated_at")

      candidate_count = issues_relation.count

      if candidate_count > 0
        logger.info(
          message: "github_sync.parse_issue_relationships",
          project_id: project.id,
          total_issues: synced_issue_ids.size,
          updated_issues: candidate_count,
          skipped_issues: synced_issue_ids.size - candidate_count
        )
      end

      client = project.github_token.client

      # Compute adjacency once before the loop for cycle detection. Within this
      # sync batch, deps created by earlier iterations won't be visible for cycle
      # detection until the next full sync — an acceptable trade-off vs N×DB reads.
      adjacency = IssueDependency.account_adjacency(project.account)
      parent_child_changed = false

      issues_relation.find_each do |issue|
        parsed_before = issue.relationships_parsed_at
        check_rate_budget!(client)
        comment_bodies = fetch_trusted_comment_bodies(client, project, issue)
        # nil means comment fetch failed — skip ALL parsing for this issue to
        # avoid stale-removal of comment-derived deps. Body-only parsing would
        # delete previously-persisted comment deps that are still valid.
        next if comment_bodies.nil?

        Issues::ParseDependencies.call(issue: issue, adjacency: adjacency, comments: comment_bodies)
        parent_child_changed |= Issues::ParseParentChild.call(issue: issue, comments: comment_bodies)

        stamp_relationships_parsed(issue, parsed_before)
      rescue GithubClient::RateLimitError
        # Always re-raise reactive rate-limit errors.
        raise
      rescue => e
        # Re-raise proactive rate-limit errors so they propagate to the
        # workflow instead of being swallowed by the generic handler.
        raise if e.is_a?(Temporalio::Error::ApplicationError) && e.type == "RateLimit"
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

      # Include pull requests so stale external deps that point at a PR in
      # this project (e.g. "Depends on owner/repo#<PR number>") get promoted
      # to local deps on sync instead of staying blocked. ready_for_work
      # then evaluates the PR's github_state correctly.
      issues_by_number = project.issues
        .where(github_number: scope.select(:depends_on_number))
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
        level = truncated ? :warn : :info
        logger.public_send(level,
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

    def reconcile_open_pull_requests(project, client)
      open_pr_numbers, truncated = fetch_open_pull_request_numbers(client, project.full_name)
      return 0 if truncated

      backfill_open_pull_requests(project, client, open_pr_numbers)
      resolve_external_dependencies(project, open_pr_numbers) if open_pr_numbers.any?
      close_stale_pull_requests(project, open_pr_numbers)
    end

    def fetch_open_pull_request_numbers(client, repo_full_name)
      prs = []
      page = 1
      truncated = false

      loop do
        page_prs = client.pull_requests(repo_full_name, state: "open", per_page: DEFAULT_PER_PAGE, page: page)
        break if page_prs.empty?

        prs.concat(page_prs)
        break if page_prs.size < DEFAULT_PER_PAGE

        page += 1
        next unless page > DEFAULT_MAX_PAGES

        truncated = client.pull_requests(repo_full_name, state: "open", per_page: DEFAULT_PER_PAGE, page: page).any?
        logger.warn(
          message: "github_sync.fetch_pull_requests_page_limit",
          repo: repo_full_name,
          fetched_count: prs.size,
          max_pages: DEFAULT_MAX_PAGES
        ) if truncated
        break
      end

      [ prs.map(&:number).uniq, truncated ]
    end

    def backfill_open_pull_requests(project, client, open_pr_numbers)
      return if open_pr_numbers.empty?

      existing_open_numbers = project.issues
        .pull_requests_only
        .where(github_state: "open", github_number: open_pr_numbers)
        .pluck(:github_number)
        .to_set

      (open_pr_numbers - existing_open_numbers.to_a).each do |number|
        github_issue = client.issue(project.full_name, number)
        sync_issue(project, github_issue)
      end
    end

    def close_stale_pull_requests(project, open_pr_numbers)
      stale_prs = project.issues
        .pull_requests_only
        .where(github_state: "open", source: Issue::GITHUB_SOURCE)
      stale_prs = stale_prs.where.not(github_number: open_pr_numbers) if open_pr_numbers.any?

      count = stale_prs.count
      return 0 if count.zero?

      stale_prs.update_all(github_state: "closed", updated_at: Time.current)
      project.broadcast_issues_update
      project.broadcast_pull_requests_update

      logger.info(
        message: "github_sync.closed_stale_pull_requests",
        project_id: project.id,
        count: count
      )

      count
    end

    # Stamp relationships_parsed_at only if a concurrent trust-policy change
    # has not cleared it (see Project#invalidate_relationship_parsing_on_trust_change).
    # Uses a conditional UPDATE keyed on the value we observed when entering
    # the loop: if the column was NULLed by a concurrent invalidation, the
    # WHERE won't match and the next sync will re-parse under the new trust list.
    def stamp_relationships_parsed(issue, parsed_before)
      scope = Issue.where(id: issue.id)
      scope = if parsed_before.nil?
        scope.where(relationships_parsed_at: nil)
      else
        scope.where(relationships_parsed_at: parsed_before)
      end
      scope.update_all(relationships_parsed_at: issue.github_updated_at)
    end
  end
end
