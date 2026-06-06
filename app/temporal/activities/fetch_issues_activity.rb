# frozen_string_literal: true

module Activities
  # Fetches open issues from GitHub for a project and syncs them to the local database.
  #
  # Returns a list of synced issue summaries for downstream processing.
  # Handles rate limiting by re-raising as a retryable Temporal error.
  class FetchIssuesActivity < BaseActivity
    DEFAULT_PER_PAGE = 100
    DEFAULT_RELATIONSHIP_PARSE_ISSUE_LIMIT = 100
    DEFAULT_RELATIONSHIP_PARSE_BUDGET_SECONDS = 30
    ISSUE_RECONCILIATION_INTERVAL = 1.hour

    def execute(input)
      project_id = input[:project_id]

      github_state = unavailable_github_state

      project = Project.find_by(id: project_id)
      return { issues: [], project_id: project_id, project_missing: true } unless project

      github_state ||= unavailable_github_state(project.github_health_endpoint)
      if github_state
        log_github_unavailable(project_id, github_state)
        return { issues: [], project_id: project_id, github_circuit_open: true }
      end

      client = project.client
      incremental = project.last_issue_sync_at.present?
      eager_queue_enabled = incremental && Issues::AutoPickProjectGate.call(project)
      sync_started_at = Time.current

      github_issues, truncated = fetch_all_issues(client, project.full_name, since: project.last_issue_sync_at)

      synced_issues = nil
      sync_changed = false
      closed_count = 0
      stale_pr_count = nil
      stale_issue_count = nil
      enhance_issue_rechecks = []
      eligible_issues = []

      Project.suppress_broadcasts do
        synced_issues = github_issues.map { |gi| sync_issue(project, gi, eager_queue_enabled: eager_queue_enabled, eligible_issues: eligible_issues) }
        sync_changed ||= synced_issues.any? { |issue_data| issue_data[:changed] }
        relationship_changes = parse_issue_relationships(project, synced_issues)
        sync_changed ||= relationship_changes

        enhance_issue_result = detect_enhance_issue_rechecks(project, synced_issues)
        enhance_issue_rechecks = enhance_issue_result[:rechecks]
        sync_changed ||= enhance_issue_result[:changed]

        needs_input_changed = detect_needs_input_label_removals(project, synced_issues)
        sync_changed ||= needs_input_changed

        closed_count = close_stale_issues(project, github_issues, truncated: truncated, incremental: incremental)
        sync_changed ||= closed_count.positive?

        if incremental && !truncated
          stale_pr_result = reconcile_open_pull_requests(project, client)
          stale_pr_count = stale_pr_result[:closed_count]
          sync_changed ||= stale_pr_result[:changed]

          stale_issue_result = reconcile_open_issues(
            project,
            client,
            eager_queue_enabled: eager_queue_enabled,
            eligible_issues: eligible_issues
          )
          stale_issue_count = stale_issue_result[:closed_count]
          sync_changed ||= stale_issue_result[:changed]
        end
        seed_eligible_issues(project, eligible_issues, incremental: incremental)
      end

      if sync_changed
        project.broadcast_project_show_refresh
      end

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
        stale_issue_count: stale_issue_count || 0,
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

    def unavailable_github_state(endpoint = GithubHealthState::DEFAULT_ENDPOINT)
      state = GithubHealthState.find_by(endpoint: endpoint)
      return unless state

      state.check_circuit_recovery!
      state if state.unavailable?
    end

    def log_github_unavailable(project_id, github_state)
      logger.info(
        message: "fetch_issues.skipped_github_unavailable",
        project_id: project_id,
        reason: github_state.rate_limited? ? "rate_limited" : "circuit_open",
        available_at: github_state.rate_limited_until&.iso8601
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

    def sync_issue(project, github_issue, eager_queue_enabled: false, eligible_issues: nil)
      creator_login = github_issue.user&.login || "unknown"
      trusted = project.trusted_github_author?(creator_login)
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
      collect_eligible_issue(project, issue, eligible_issues) if eager_queue_enabled

      { id: issue.id, github_number: issue.github_number, labels: issue.labels,
        github_state: issue.github_state, trusted: trusted, removed_labels: previous_labels - issue.labels,
        changed: issue.previous_changes.present? }
    end

    def collect_eligible_issue(project, issue, eligible_issues)
      return unless project.auto_pick_enabled?
      return unless issue.github_state == "open"
      return if issue.is_pull_request?

      eligible_issues << issue
    end

    def seed_eligible_issues(project, eligible_issues, incremental:)
      if incremental
        eligible_issues.each do |issue|
          Issues::EnqueueEligible.call(issue, project: project, skip_project_gate: true)
        end
      else
        Issues::BulkEnqueueEligible.call(project: project)
      end
    rescue => e
      logger.error(
        message: "github_sync.seed_eligible_failed",
        project_id: project.id,
        incremental: incremental,
        error: e.message
      )
    end

    def detect_enhance_issue_rechecks(project, synced_issues)
      label = project.enhance_issue_needs_input_label_name
      changed = false

      rechecks = synced_issues.filter_map do |issue_data|
        next unless Array(issue_data[:removed_labels]).include?(label)

        issue = project.issues.find(issue_data[:id])
        next if issue.is_pull_request? || issue.github_state == "closed" || issue.paid_state != "needs_input"

        changed = true
        enqueue_enhance_issue_recheck(project, issue)
      end

      { rechecks: rechecks, changed: changed }
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
      project.client.add_comment(
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

    def detect_needs_input_label_removals(project, synced_issues)
      needs_input_label = project.label_for_stage("needs_input") ||
        Activities::HandleNoOutputIssueRunActivity::PAID_NEEDS_INPUT_LABEL
      changed = false

      synced_issues.each do |issue_data|
        next unless Array(issue_data[:removed_labels]).include?(needs_input_label)

        issue = project.issues.find(issue_data[:id])
        next if issue.is_pull_request? || issue.github_state == "closed" || issue.paid_state != "needs_input"

        issue.update!(paid_state: "new")
        changed = true

        logger.info(
          message: "github_sync.needs_input_label_removed",
          project_id: project.id,
          issue_id: issue.id,
          issue_number: issue.github_number
        )
      end

      changed
    end

    # Parses dependency and parent/child relationships from issue comments.
    # Re-parses issues whose github_updated_at has advanced beyond their last
    # successful parse, as well as issues never parsed or whose previous parse
    # failed — relationships_parsed_at is only bumped on success, so transient
    # fetch errors naturally retry on the next sync. Trust-policy changes clear
    # relationships_parsed_at on the project's issues to force reparse (see
    # Project#invalidate_relationship_parsing_on_trust_change).
    def parse_issue_relationships(project, synced_issues)
      issues_relation = relationship_parse_candidates(project)

      candidate_count = issues_relation.count
      issue_limit = relationship_parse_issue_limit
      parse_budget_seconds = relationship_parse_budget_seconds
      issues = issues_relation.limit(issue_limit).to_a
      deferred_count = candidate_count - issues.size

      if candidate_count > 0
        logger.info(
          message: "github_sync.parse_issue_relationships",
          project_id: project.id,
          total_issues: project.issues.where(github_state: "open", is_pull_request: false).count,
          candidate_issues: candidate_count,
          selected_issues: issues.size,
          deferred_issues: deferred_count,
          issue_limit: issue_limit,
          budget_seconds: parse_budget_seconds
        )
      end

      client = project.client
      deadline = monotonic_now + parse_budget_seconds

      # Compute adjacency once before the loop for cycle detection. Within this
      # sync batch, deps created by earlier iterations won't be visible for cycle
      # detection until the next full sync — an acceptable trade-off vs N×DB reads.
      adjacency = IssueDependency.account_adjacency(project.account)
      parent_child_changed = false

      # Batch-fetch comments for all candidate issues in one GraphQL request
      # instead of N separate REST calls.
      comments_by_number = fetch_batch_comments(client, project, issues)

      issues.each_with_index do |issue, index|
        if index.positive? && monotonic_now >= deadline
          deferred_count += issues.size - index
          logger.warn(
            message: "github_sync.parse_issue_relationships_budget_exhausted",
            project_id: project.id,
            candidate_issues: candidate_count,
            processed_issues: index,
            deferred_issues: deferred_count,
            issue_limit: issue_limit,
            budget_seconds: parse_budget_seconds
          )
          break
        end

        parsed_before = issue.relationships_parsed_at
        check_rate_budget!(client)

        github_comments = comments_by_number[issue.github_number]
        # nil means the batch fetch failed entirely — skip ALL parsing for
        # this issue to avoid stale-removal of comment-derived deps.
        next if github_comments.nil?

        comment_bodies = github_comments
          .select { |c| project.trusted_github_user?(c.user&.login) }
          .map { |c| c.body.to_s }

        Issues::ParseDependencies.call(issue: issue, adjacency: adjacency, comments: comment_bodies)
        parent_child_changed |= Issues::ParseParentChild.call(issue: issue, comments: comment_bodies)

        stamp_relationships_parsed(issue, parsed_before)
      rescue GithubClient::RateLimitError
        # Always re-raise reactive rate-limit errors.
        raise
      rescue => e
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

      # ParseParentChild returns true when either child-list reconciliation or
      # inline parent declarations changed visible issue relationships.
      synced_numbers = synced_issues.filter_map { |si| si[:github_number] }
      dependency_changed = resolve_external_dependencies(project, synced_numbers)
      parent_child_changed || dependency_changed
    end

    def relationship_parse_candidates(project)
      project.issues
        .where(github_state: "open", is_pull_request: false)
        .where.not(github_updated_at: nil)
        .where("relationships_parsed_at IS NULL OR relationships_parsed_at < github_updated_at")
        .order(:relationships_parsed_at, :github_updated_at, :id)
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

      changed = false

      scope.find_each do |dep|
        resolved_issue = issues_by_number[dep.depends_on_number]
        next unless resolved_issue

        if IssueDependency.exists?(issue_id: dep.issue_id, depends_on_issue_id: resolved_issue.id)
          dep.destroy!
          changed = true
          next
        end

        begin
          dep.update!(
            depends_on_issue: resolved_issue,
            depends_on_owner: nil,
            depends_on_repo: nil,
            depends_on_number: nil
          )
          changed = true
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
          changed = true
        end
      end

      changed
    rescue => e
      logger.warn(
        message: "github_sync.resolve_external_dependencies_failed",
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    # Batch-fetches comments for all candidate issues in a single GraphQL request.
    # Returns a Hash mapping issue number to an array of comment objects, or nil
    # for issues whose comments could not be fetched. Returning nil (vs empty
    # array) lets callers distinguish "no comments" from "fetch failed", avoiding
    # accidental deletion of comment-derived dependencies.
    def fetch_batch_comments(client, project, issues)
      issue_numbers = issues.map(&:github_number)
      return {} if issue_numbers.empty?

      result = client.issue_comments_batch(project.full_name, issue_numbers)
      issue_numbers.to_h { |n| [ n, result.fetch(n, []) ] }
    rescue GithubClient::RateLimitError
      raise
    rescue => e
      logger.warn(
        message: "github_sync.fetch_batch_comments_failed",
        project_id: project.id,
        issue_count: issues.size,
        error_class: e.class.name,
        error: e.message
      )
      issues.map { |issue| [ issue.github_number, nil ] }.to_h
    end

    def relationship_parse_issue_limit
      Integer(ENV.fetch("FETCH_ISSUES_RELATIONSHIP_PARSE_ISSUE_LIMIT", DEFAULT_RELATIONSHIP_PARSE_ISSUE_LIMIT))
    end

    def relationship_parse_budget_seconds
      Integer(ENV.fetch("FETCH_ISSUES_RELATIONSHIP_PARSE_BUDGET_SECONDS", DEFAULT_RELATIONSHIP_PARSE_BUDGET_SECONDS))
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
      return { changed: false, closed_count: 0 } if truncated

      backfilled_count = backfill_open_pull_requests(project, client, open_pr_numbers)
      dependency_changed = open_pr_numbers.any? && resolve_external_dependencies(project, open_pr_numbers)
      closed_count = close_stale_pull_requests(project, open_pr_numbers, client: client)

      {
        changed: backfilled_count.positive? || dependency_changed || closed_count.positive?,
        closed_count: closed_count
      }
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
      return 0 if open_pr_numbers.empty?

      existing_open_numbers = project.issues
        .pull_requests_only
        .where(github_state: "open", github_number: open_pr_numbers)
        .pluck(:github_number)
        .to_set

      missing_numbers = open_pr_numbers - existing_open_numbers.to_a

      missing_numbers.each do |number|
        github_issue = client.issue(project.full_name, number)
        sync_issue(project, github_issue)
      end

      missing_numbers.size
    end

    def close_stale_pull_requests(project, open_pr_numbers, client:)
      stale_prs = project.issues
        .pull_requests_only
        .where(github_state: "open", source: Issue::GITHUB_SOURCE)
      stale_prs = stale_prs.where.not(github_number: open_pr_numbers) if open_pr_numbers.any?

      count = stale_prs.count
      return 0 if count.zero?

      merged_numbers, unmerged_numbers, unknown_numbers = partition_by_merge_status(
        client, project.full_name, stale_prs.pluck(:github_number)
      )

      if merged_numbers.any?
        project.issues
          .pull_requests_only
          .where(project_id: project.id, github_number: merged_numbers)
          .update_all(github_state: "closed", pr_review_phase: "merged", updated_at: Time.current)
      end

      if unmerged_numbers.any?
        project.issues
          .pull_requests_only
          .where(project_id: project.id, github_number: unmerged_numbers)
          .update_all(github_state: "closed", updated_at: Time.current)
      end

      closed_numbers = merged_numbers.size + unmerged_numbers.size

      logger.info(
        message: "github_sync.closed_stale_pull_requests",
        project_id: project.id,
        count: closed_numbers,
        merged_count: merged_numbers.size,
        unknown_count: unknown_numbers.size
      )

      closed_numbers
    end

    def partition_by_merge_status(client, repo_full_name, pr_numbers)
      merged_numbers = []
      unmerged_numbers = []
      unknown_numbers = []

      pr_numbers.each do |number|
        github_pr = client.pull_request(repo_full_name, number)
        if github_pr.merged_at.present? || github_pr.merged == true
          merged_numbers << number
        else
          unmerged_numbers << number
        end
      rescue GithubClient::RateLimitError
        raise
      rescue => e
        logger.warn(
          message: "github_sync.stale_pr_merge_check_failed",
          repo: repo_full_name,
          pr_number: number,
          error_class: e.class.name,
          error: e.message
        )
        unknown_numbers << number
      end

      [ merged_numbers, unmerged_numbers, unknown_numbers ]
    end

    # Mirrors reconcile_open_pull_requests for issues. Fetches all open issue
    # numbers from GitHub and closes locally-open issues not in that set.
    # Gated by ISSUE_RECONCILIATION_INTERVAL (default 1 hour) to limit API
    # cost, since issue counts can be much larger than PR counts.
    def reconcile_open_issues(project, client, eager_queue_enabled: false, eligible_issues: nil)
      return { changed: false, closed_count: 0 } unless issue_reconciliation_due?(project)

      open_numbers, truncated = fetch_open_issue_numbers(client, project.full_name)

      project.update_column(:last_issue_reconciliation_at, Time.current)

      if truncated
        logger.warn(
          message: "github_sync.issue_reconciliation_skipped_truncated",
          project_id: project.id
        )
        return { changed: false, closed_count: 0 }
      end

      backfilled_count = backfill_open_issues(
        project,
        client,
        open_numbers,
        eager_queue_enabled: eager_queue_enabled,
        eligible_issues: eligible_issues
      )

      stale = project.issues
        .where(github_state: "open", is_pull_request: false, source: Issue::GITHUB_SOURCE)
      stale = stale.where.not(github_number: open_numbers) if open_numbers.any?

      count = stale.count
      if count > 0
        stale.update_all(github_state: "closed", updated_at: Time.current)

        logger.info(
          message: "github_sync.reconciled_stale_issues",
          project_id: project.id,
          count: count
        )
      end

      {
        changed: backfilled_count.positive? || count.positive?,
        closed_count: count
      }
    end

    def backfill_open_issues(project, client, open_issue_numbers, eager_queue_enabled: false, eligible_issues: nil)
      return 0 if open_issue_numbers.empty?

      existing_open_numbers = project.issues
        .where(github_state: "open", is_pull_request: false, github_number: open_issue_numbers)
        .pluck(:github_number)
        .to_set

      missing_numbers = open_issue_numbers - existing_open_numbers.to_a

      missing_numbers.each do |number|
        github_issue = client.issue(project.full_name, number)
        sync_issue(
          project,
          github_issue,
          eager_queue_enabled: eager_queue_enabled,
          eligible_issues: eligible_issues
        )
      end

      missing_numbers.size
    end

    def issue_reconciliation_due?(project)
      last = project.last_issue_reconciliation_at
      last.nil? || last < ISSUE_RECONCILIATION_INTERVAL.ago
    end

    def fetch_open_issue_numbers(client, repo_full_name)
      numbers = []
      page = 1
      truncated = false

      loop do
        page_issues = client.issues(repo_full_name, state: "open", per_page: DEFAULT_PER_PAGE, page: page)
        break if page_issues.empty?

        numbers.concat(page_issues.reject { |i| i.respond_to?(:pull_request) && i.pull_request }.filter_map(&:number))
        break if page_issues.size < DEFAULT_PER_PAGE

        page += 1
        next unless page > DEFAULT_MAX_PAGES

        truncated = client.issues(repo_full_name, state: "open", per_page: DEFAULT_PER_PAGE, page: page).any?
        logger.warn(
          message: "github_sync.fetch_issue_numbers_page_limit",
          repo: repo_full_name,
          fetched_count: numbers.size,
          max_pages: DEFAULT_MAX_PAGES
        ) if truncated
        break
      end

      [ numbers.uniq, truncated ]
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
