# frozen_string_literal: true

module Activities
  # Scans open pull requests with the automation label for signals
  # that require follow-up agent work. Runs after FetchIssuesActivity in
  # the GitHubPollWorkflow poll cycle.
  #
  # Phase-aware routing:
  #   - draft: All signals (CI, review bots, human reviews). All followups
  #     count toward max_draft_review_rounds to prevent infinite loops.
  #   - ready: Owner approval takes precedence and may trigger auto-merge;
  #     other signals (CI, review bots, human reviews, labels, merge conflicts)
  #     are only considered while awaiting owner approval.
  #   - escalated: Same signal handling as ready, but no auto-merge
  #   - merged: No scanning
  #
  # Returns a list of PRs needing follow-up with trigger reasons.
  class ScanPaidPrsActivity < BaseActivity
    activity_name "ScanPaidPrs"

    MIN_COMMENT_LENGTH = 20
    KNOWN_BOT_PREFIXES = %w[dependabot renovate github-actions].freeze
    REVIEW_BOT_CLEAN_PATTERN = /generated no (?:new )?comments/i
    # Body-only review bots (currently Codex) signal "no findings" by posting
    # an *issue comment* — not a review — with text like
    # "Codex Review: Didn't find any major issues. Bravo." Match the
    # distinctive phrase rather than the prefix so we are robust to minor
    # wording changes.
    BODY_ONLY_BOT_CLEAN_COMMENT_PATTERN = /didn'?t find any (?:major )?issues/i

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { prs_to_trigger: [], project_missing: true } unless project
      return { prs_to_trigger: [] } unless project.auto_scan_prs

      client = project.github_token.client
      paid_prs = find_paid_prs(project)

      prs_to_trigger = paid_prs.filter_map { |issue| scan_pr(project, client, issue) }

      logger.info(
        message: "pr_scanner.scan_complete",
        project_id: project_id,
        prs_scanned: paid_prs.size,
        prs_triggered: prs_to_trigger.size
      )

      { prs_to_trigger: prs_to_trigger }
    end

    private

    def find_paid_prs(project)
      project.issues
        .pull_requests_only
        .auto_continue_active
        .where(github_state: "open")
        .where("labels @> ?", [ project.automation_label_name ].to_json)
    end

    def scan_pr(project, client, issue)
      return nil if active_run_exists?(project, issue)

      case issue.pr_review_phase
      when "draft", "restarted"
        scan_draft_pr(project, client, issue)
      when "ready"
        pr_data = fetch_pr_data(client, project, issue)
        if maybe_restart_draft(project, issue, pr_data)
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        else
          scan_ready_pr(project, client, issue, pr_data: pr_data)
        end
      when "escalated"
        pr_data = fetch_pr_data(client, project, issue)
        if maybe_restart_draft(project, issue, pr_data)
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        else
          scan_escalated_pr(project, client, issue, pr_data: pr_data)
        end
      end
    end

    MAX_CONSECUTIVE_DRAFT_FAILURES = 3

    # --- Draft phase scanning ---

    def scan_draft_pr(project, client, issue, pr_data: nil)
      if project.max_draft_review_rounds.positive? &&
          issue.draft_review_count >= project.max_draft_review_rounds
        return escalate_trigger(issue)
      end

      if consecutive_draft_failures_breaker?(project, issue)
        return escalate_trigger(issue, reason: "Consecutive draft follow-up failures (#{MAX_CONSECUTIVE_DRAFT_FAILURES} runs with no output)")
      end

      skip_comment_signals = project.max_draft_review_rounds.zero?
      unresolved_threads = nil
      human_triggers = []
      review_bot_triggers = []
      reviews = nil
      # Needed by check_review_bot_status for the body-only bot anti-loop
      # guard (e.g. Codex); also reused by comment/changes-requested checks
      # below when comment signals are not skipped.
      last_run = last_completed_run(project, issue)

      # Draft exit still requires an explicitly clean bot review even when
      # other draft comment signals are skipped.
      if skip_comment_signals
        reviews = fetch_reviews(client, project, issue)
        review_bot_triggers = check_review_bot_status(reviews, unresolved_threads,
          project: project, last_run: last_run, client: client, issue: issue)
      else
        # Fetch review threads first; only fetch full reviews when needed.
        unresolved_threads = fetch_unresolved_threads(client, project, issue)
        human_triggers = human_review_thread_triggers(project, unresolved_threads)

        if human_triggers.blank?
          reviews = fetch_reviews(client, project, issue)
          review_bot_triggers = check_review_bot_status(reviews, unresolved_threads,
            project: project, last_run: last_run, client: client, issue: issue)
        end
      end

      # review_bot_review_pending and paid_agent_review_pending are
      # non-blocking: they request a review but should not prevent evaluation
      # of CI, comments, or changes_requested.
      review_pending_types = %w[review_bot_review_pending paid_agent_review_pending].freeze
      pending_triggers = (review_bot_triggers || []).select { |t| review_pending_types.include?(t[:type]) }
      blocking_triggers = (review_bot_triggers || []).reject { |t| review_pending_types.include?(t[:type]) }
      all_triggers = blocking_triggers + (human_triggers || [])

      # Only fetch PR data and check runs if blocking review triggers aren't enough.
      if all_triggers.empty?
        pr_data ||= fetch_pr_data(client, project, issue)
        checks = fetch_check_runs(client, project, pr_data)
        ci_triggers = ci_failure_triggers(checks || [])
        all_triggers.concat(ci_triggers)
      end

      # Only fetch conversation comments if still no triggers.
      if all_triggers.empty? && !skip_comment_signals
        all_triggers.concat(check_conversation_comments(client, project, issue, last_run))

        # Only check changes_requested if still no triggers.
        if all_triggers.empty?
          reviews ||= fetch_reviews(client, project, issue)
          all_triggers.concat(changes_requested_from_reviews(project, reviews, last_run))
        end
      end

      if all_triggers.empty?
        # If we couldn't fetch PR data, don't prematurely advance the phase.
        return nil if pr_data.nil?
        return nil if reviews.nil?

        # A draft PR is only ready to leave draft after the latest review-bot
        # review is explicitly clean. Resolved threads alone are not enough.
        if pending_triggers.any?
          triggers = pending_triggers
          log_triggers(project, issue, triggers)
          return draft_trigger_payload(issue, triggers)
        end

        # Only auto-advance when we have at least one check and all conclusions are green.
        # all_checks_green? implicitly rejects nil conclusions (pending checks),
        # and only after a clean review-bot review is present.
        if checks.present? && all_checks_green?(checks)
          return ready_for_owner_trigger(issue)
        end

        return nil # CI still pending or checks unavailable
      end

      # Re-add pending triggers so the workflow can request the review.
      all_triggers.concat(pending_triggers)

      triggers = all_triggers
      log_triggers(project, issue, triggers)
      draft_trigger_payload(issue, triggers)
    end

    # --- Ready phase scanning ---

    def scan_ready_pr(project, client, issue, pr_data:)
      return nil if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      reviews = fetch_reviews(client, project, issue)
      mergeable = pr_data && pr_data[:mergeable]

      if project.auto_merge_enabled? &&
          pr_data.present? &&
          owner_approved_or_self_authored?(project, reviews, pr_data) &&
          checks.present? &&
          all_checks_green?(checks) &&
          mergeable == true &&
          no_outstanding_review_feedback?(project, client, issue, reviews)
        return owner_approved_trigger(issue)
      end

      return nil if followup_limit_reached?(project, issue)

      triggers = detect_ready_triggers(project, client, issue,
        pr_data: pr_data, checks: checks, reviews: reviews)
      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: "ready",
        labels_to_remove: extract_actionable_labels(triggers),
        current_followup_count: issue.pr_followup_count
      }
    end

    # --- Escalated phase scanning ---

    def scan_escalated_pr(project, client, issue, pr_data: nil)
      return nil if followup_limit_reached?(project, issue)

      triggers = detect_ready_triggers(project, client, issue, pr_data: pr_data)
      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: "escalated",
        labels_to_remove: extract_actionable_labels(triggers),
        current_followup_count: issue.pr_followup_count
      }
    end

    # --- Special trigger builders ---

    def ready_for_owner_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "ready_for_owner" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "ready_for_owner", details: "CI green, review bots clean" } ],
        phase: issue.pr_review_phase,
        owner_reviewer_login: issue.project.owner_reviewer_login
      }
    end

    def escalate_trigger(issue, reason: "Draft review limit reached")
      log_triggers(issue.project, issue, [ { type: "escalate_to_owner" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "escalate_to_owner", details: reason } ],
        phase: issue.pr_review_phase,
        current_draft_review_count: issue.draft_review_count,
        owner_reviewer_login: issue.project.owner_reviewer_login
      }
    end

    def owner_approved_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "owner_approved" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "owner_approved", details: "Owner approval requirement satisfied" } ],
        phase: "ready"
      }
    end

    def draft_trigger_payload(issue, triggers)
      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: issue.pr_review_phase,
        labels_to_remove: [],
        current_draft_review_count: issue.draft_review_count
      }
    end

    # --- Shared detection logic ---

    def detect_ready_triggers(project, client, issue, pr_data: nil, checks: nil, reviews: nil,
      unresolved_threads: nil)
      last_run = last_completed_run(project, issue)
      pr_data ||= fetch_pr_data(client, project, issue)
      checks ||= fetch_check_runs(client, project, pr_data)
      reviews ||= fetch_reviews(client, project, issue)
      unresolved_threads ||= fetch_unresolved_threads(client, project, issue)
      triggers = []

      triggers.concat(ci_failure_triggers(checks))
      triggers.concat(check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue))
      triggers.concat(human_review_thread_triggers(project, unresolved_threads))
      triggers.concat(check_conversation_comments(client, project, issue, last_run))
      triggers.concat(changes_requested_from_reviews(project, reviews, last_run))
      triggers.concat(check_actionable_labels(project, issue))
      triggers.concat(check_merge_conflicts(project, pr_data))

      triggers
    end

    # Detect when a user converts a ready/escalated PR back to draft on GitHub.
    # Reset counts and transition to "restarted" phase so the scanner treats it
    # like a fresh draft PR. Returns true if the phase was restarted.
    def maybe_restart_draft(project, issue, pr_data)
      return false unless pr_data&.draft

      issue.update!(
        pr_review_phase: "restarted",
        draft_review_count: 0,
        pr_followup_count: 0
      )

      logger.info(
        message: "pr_scanner.phase_restarted",
        project_id: project.id,
        pr_number: issue.github_number,
        previous_phase: issue.pr_review_phase_before_last_save
      )

      true
    end

    def active_run_exists?(project, issue)
      project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .where(status: AgentRun::UNFINISHED_STATUSES)
        .where(goal: "create_pr")
        .exists?
    end

    def followup_limit_reached?(project, issue)
      issue.pr_followup_count >= project.max_pr_followup_runs
    end

    # Circuit breaker: if the last N automatic draft follow-up runs on
    # this PR all ended without producing any output (timeout/failed/
    # cancelled with zero iterations), stop requeueing to prevent
    # infinite retry loops. Scoped to automatic create_pr runs so that
    # manual runs or review-phase followups don't trip the breaker.
    #
    # The draft_review_count guard ensures we only consider runs from the
    # current draft phase. maybe_restart_draft resets draft_review_count
    # to 0, so older non-draft failures can't trip the breaker when a PR
    # is converted back to draft.
    def consecutive_draft_failures_breaker?(project, issue)
      return false if issue.draft_review_count < MAX_CONSECUTIVE_DRAFT_FAILURES

      failure_statuses = AgentRun::FAILURE_STATUSES + %w[cancelled]

      recent_runs = project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .where(trigger_type: "automatic", goal: "create_pr")
        .finished
        .order(created_at: :desc)
        .limit(MAX_CONSECUTIVE_DRAFT_FAILURES)

      return false if recent_runs.size < MAX_CONSECUTIVE_DRAFT_FAILURES

      recent_runs.all? do |run|
        failure_statuses.include?(run.status) && run.iterations.to_i.zero?
      end
    end

    def last_completed_run(project, issue)
      project.agent_runs
        .where(
          "source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
          pr_num: issue.github_number
        )
        .completed
        .order(completed_at: :desc)
        .first
    end

    def fetch_pr_data(client, project, issue)
      client.pull_request(project.full_name, issue.github_number)
    rescue GithubClient::Error => e
      log_signal_error("fetch_pr", project, issue, e)
      nil
    end

    # --- CI checks ---

    def fetch_check_runs(client, project, pr_data)
      return [] unless pr_data

      client.check_runs_for_ref(project.full_name, pr_data.head.sha)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_scanner.ci_check_failed",
        project_id: project.id,
        error: e.message
      )
      []
    end

    def ci_failure_triggers(checks)
      completed = checks.select { |c| c[:conclusion].present? }
      return [] if completed.empty?

      failed = completed.select { |c| %w[failure cancelled timed_out action_required stale].include?(c[:conclusion]) }
      return [] if failed.empty?

      [ { type: "ci_failure", details: failed.map { |c| c[:name] } } ]
    end

    def all_checks_green?(checks)
      return true if checks.empty?

      checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
    end

    # --- Review checks ---

    def fetch_unresolved_threads(client, project, issue)
      threads = client.review_threads(project.full_name, issue.github_number)
      threads.reject { |t| t[:is_resolved] }
    rescue GithubClient::Error => e
      log_signal_error("review_threads", project, issue, e)
      nil
    end

    def human_review_thread_triggers(project, unresolved_threads)
      return [] if unresolved_threads.nil?

      trusted_threads = unresolved_threads.select do |thread|
        thread[:comments].any? do |c|
          project.trusted_github_user?(c[:author]) && !bot_user?(c[:author])
        end
      end

      return [] if trusted_threads.empty?

      [ { type: "review_threads", details: "#{trusted_threads.size} unresolved thread(s)" } ]
    end

    def review_bot_review_status(reviews, allowed_bot_logins: nil)
      return :unknown if reviews.nil?

      review_bot_review_status_from(reviews, latest_allowed_bot_review(reviews, allowed_bot_logins))
    end

    # Shared status classifier so callers that have already resolved the
    # latest allowed bot review (e.g. check_review_bot_status) do not have
    # to iterate reviews a second time.
    def review_bot_review_status_from(reviews, latest)
      return :unknown if reviews.nil?
      return :no_review if latest.nil?

      REVIEW_BOT_CLEAN_PATTERN.match?(latest[:body]) ? :clean : :has_comments
    end

    def latest_allowed_bot_review(reviews, allowed_bot_logins)
      return nil if reviews.nil?

      bot_reviews = reviews.select do |r|
        next false unless review_bot?(r[:user_login])
        next true if allowed_bot_logins.nil?

        allowed_bot_logins.include?(r[:user_login]&.downcase)
      end
      bot_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
    end

    # Returns the login that should be explicitly requested for a review-bot
    # review, or nil when no enabled review method has a bot that accepts
    # explicit review requests. See Project#review_bot_request_login for the
    # precedence rules.
    def review_bot_request_login(project)
      project.review_bot_request_login
    end

    # Review-bot logins that post feedback as a single top-level review body
    # rather than as inline review threads. These bots need the body-only
    # anti-loop guard in check_review_bot_status because thread resolution
    # cannot be used to detect "already addressed" state.
    BODY_ONLY_REVIEW_BOT_LOGINS = ProviderSupport::PROVIDER_BOT_USERNAMES
      .fetch("codex", [])
      .map(&:downcase)
      .to_set
      .freeze

    def check_review_bot_status(reviews, unresolved_threads, project: nil, last_run: nil, client: nil, issue: nil)
      allowed = project&.review_enabled? ? (project.enabled_review_bot_logins.presence || Set.new) : nil
      latest = latest_allowed_bot_review(reviews, allowed)

      # Body-only bots (Codex) can post their CLEAN signal as an issue
      # comment — e.g. "Codex Review: Didn't find any major issues. Bravo." —
      # which is invisible to pull_request_reviews. When such a comment is
      # the most recent body-only-bot signal on the PR, treat the bot as
      # clean regardless of any older non-clean review. Without this check,
      # the @codex review trigger loop would re-emit pending triggers
      # forever and wedge codex-only PRs in draft.
      #
      # The bypass is restricted to projects whose enabled review bots are
      # ALL body-only so a clean codex comment cannot suppress an outstanding
      # Copilot review in mixed configurations.
      if client && issue && body_only_bot_clean_comment_present?(client, project, issue, latest, allowed)
        return []
      end

      status = review_bot_review_status_from(reviews, latest)

      case status
      when :clean
        []
      when :no_review
        # Only emit a pending trigger when a requestable review bot is
        # configured. When login is nil — reviews globally disabled, or
        # only non-bot review methods (e.g. manual) are enabled — there is
        # no bot that could satisfy the trigger, so emitting it would wedge
        # the draft scanner in a perpetual "waiting for bot review" state
        # with no path out (handle_review_bot_review_pending skips the
        # RequestReviewActivity call when login is nil).
        login = project && review_bot_request_login(project)
        if login
          [ { type: "review_bot_review_pending", details: "No review bot review found", request_login: login } ]
        elsif project&.review_enabled? && project.review_method_enabled?("paid_agent")
          check_paid_agent_review_status(project, issue)
        else
          []
        end
      when :has_comments
        # When unresolved_threads is nil, threads were either never fetched
        # (e.g. the skip_comment_signals path) or the API call failed. We
        # cannot tell whether bot threads are truly resolved, so treat the
        # status as pending to avoid prematurely advancing the PR.
        if unresolved_threads.nil?
          [ { type: "review_bot_review_pending", details: "Latest review bot review was not clean" } ]
        else
          bot_thread_triggers = review_bot_thread_triggers(unresolved_threads)
          if bot_thread_triggers.any?
            # Thread-based bots (e.g. Copilot) with at least one unresolved
            # bot thread: emit review_bot_comments + the thread triggers.
            triggers = [ { type: "review_bot_review_pending", details: "Latest review bot review was not clean" } ]
            triggers << { type: "review_bot_comments", details: "Latest review bot review generated comments" }
            triggers.concat(bot_thread_triggers)
            triggers
          elsif body_only_review_bot?(latest&.dig(:user_login)) &&
              body_only_review_needs_followup?(latest, last_run)
            # Body-only bots (e.g. Codex): the review feedback lives in
            # the top-level review body with no inline threads, so thread
            # resolution cannot gate re-review. Use submitted_at vs the
            # last agent run's completed_at as the anti-loop guard — a
            # review post-dating the last run is unaddressed feedback.
            # The "(body-only)" suffix on review_bot_comments lets
            # structured-log consumers distinguish this path from the
            # thread-based Copilot flow above.
            [
              { type: "review_bot_review_pending", details: "Latest review bot review was not clean" },
              { type: "review_bot_comments", details: "Latest review bot review generated comments (body-only)" }
            ]
          else
            # Thread-based bot with all bot threads resolved, or body-only
            # review already addressed by a subsequent agent run. Treat as
            # effectively clean to avoid re-requesting reviews that would
            # produce no new comments.
            []
          end
        end
      when :unknown
        review_bot_thread_triggers(unresolved_threads)
      end
    end

    # Checks whether a paid_agent review-goal run is needed for this PR.
    # Returns a paid_agent_review_pending trigger when no completed review-goal
    # run exists and the max_review_rounds limit has not been reached. Returns
    # an empty array when the review is already satisfied or the limit is hit.
    def check_paid_agent_review_status(project, issue)
      return [] unless issue

      pr_number = issue.github_number
      review_runs = project.agent_runs.where(
        source_pull_request_number: pr_number,
        goal: "review"
      )

      # A review-goal run is already queued or running — no new trigger needed.
      return [] if review_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?

      completed_count = review_runs.where(status: "completed").count
      max_rounds = project.review_method_config("paid_agent")
        .dig("termination", "max_review_rounds")

      if max_rounds.present? && completed_count >= max_rounds.to_i
        return []
      end

      # Check whether the most recent completed review-goal run was posted
      # after the last create_pr run. If so, the review is already up to date.
      last_review_run = review_runs.where(status: "completed")
        .order(completed_at: :desc).first
      last_create_run = last_completed_run(project, issue)

      if last_review_run && last_create_run &&
          last_review_run.completed_at >= last_create_run.completed_at
        return []
      end

      [ { type: "paid_agent_review_pending", details: "No paid_agent review found for PR" } ]
    end

    def body_only_review_bot?(login)
      return false if login.nil?

      BODY_ONLY_REVIEW_BOT_LOGINS.include?(login.downcase)
    end

    # Returns true when the most recent issue comment authored by a body-only
    # review bot (e.g. Codex) matches the clean signal pattern AND can speak
    # authoritatively for the project's review configuration AND is at least
    # as recent as that bot's latest review on this PR.
    #
    # The override is restricted to projects whose enabled review bots are
    # ALL body-only — i.e. no thread-based bot like Copilot is also enabled.
    # A clean codex comment cannot speak for an outstanding Copilot review
    # whose unresolved threads are tracked separately, so in mixed
    # configurations we defer to the existing classification path.
    #
    # The comment-vs-review timestamp comparison prevents an older "Bravo"
    # comment from masking a newer non-clean review on a subsequent commit.
    def body_only_bot_clean_comment_present?(client, project, issue, latest_review, allowed_bot_logins)
      return false if allowed_bot_logins.nil? || allowed_bot_logins.empty?
      return false unless allowed_bot_logins.subset?(BODY_ONLY_REVIEW_BOT_LOGINS)

      comments = client.recent_issue_comments(project.full_name, issue.github_number)
      bot_comments = comments.select do |c|
        login = c.user&.login&.downcase
        login && allowed_bot_logins.include?(login)
      end
      return false if bot_comments.empty?

      latest_bot_comment = bot_comments.max_by { |c| c.created_at || Time.at(0) }
      return false unless BODY_ONLY_BOT_CLEAN_COMMENT_PATTERN.match?(latest_bot_comment.body.to_s)

      review_time = latest_review&.dig(:submitted_at)
      comment_time = latest_bot_comment.created_at
      return true if review_time.nil? || comment_time.nil?

      comment_time >= review_time
    rescue GithubClient::Error => e
      log_signal_error("body_only_bot_clean_comment", project, issue, e)
      false
    end

    # Anti-loop guard for body-only review bots: returns true when the bot's
    # latest review was submitted after the last agent run completed, meaning
    # the agent has not yet addressed the feedback. Treats missing timestamps
    # conservatively as "needs follow-up" to avoid silently dropping
    # actionable review content.
    def body_only_review_needs_followup?(latest_review, last_run)
      return false if latest_review.nil?

      submitted_at = latest_review[:submitted_at]
      return true if submitted_at.nil?

      cutoff = last_run&.completed_at
      return true if cutoff.nil?

      submitted_at > cutoff
    end

    def review_bot_thread_triggers(unresolved_threads)
      return [] if unresolved_threads.nil?

      review_bot_threads = unresolved_threads.select do |thread|
        thread[:comments].any? { |c| review_bot?(c[:author]) }
      end

      return [] if review_bot_threads.empty?

      [ { type: "review_bot_threads", details: "#{review_bot_threads.size} unresolved review bot thread(s)" } ]
    end

    def check_conversation_comments(client, project, issue, last_run)
      comments = client.issue_comments(project.full_name, issue.github_number)
      cutoff = last_run&.completed_at

      relevant = comments.select do |c|
        login = c.user&.login
        next false if bot_user?(login)
        next false unless project.trusted_github_user?(login)
        next false if cutoff && c.created_at <= cutoff
        next false if system_generated_comment?(c.body)
        next false if c.body.to_s.strip.length < MIN_COMMENT_LENGTH

        true
      end

      return [] if relevant.empty?

      [ { type: "conversation_comments", details: "#{relevant.size} new comment(s)" } ]
    rescue GithubClient::Error => e
      log_signal_error("conversation_comments", project, issue, e)
      []
    end

    def fetch_reviews(client, project, issue)
      client.pull_request_reviews(project.full_name, issue.github_number)
    rescue GithubClient::Error => e
      log_signal_error("fetch_reviews", project, issue, e)
      nil
    end

    def changes_requested_from_reviews(project, reviews, last_run)
      return [] if reviews.nil?

      cutoff = last_run&.completed_at

      latest_by_user = reviews
        .select { |r| project.trusted_github_user?(r[:user_login]) && !bot_user?(r[:user_login]) }
        .group_by { |r| r[:user_login]&.downcase }
        .transform_values { |user_reviews| user_reviews.max_by { |r| r[:submitted_at] || Time.at(0) } }

      changes_requested = latest_by_user.values.select do |review|
        next false unless review[:state] == "CHANGES_REQUESTED"
        next false if cutoff && review[:submitted_at] && review[:submitted_at] <= cutoff

        true
      end

      return [] if changes_requested.empty?

      [ { type: "changes_requested", details: changes_requested.map { |r| r[:user_login] } } ]
    end

    def check_actionable_labels(project, issue)
      action_labels = project.pr_action_labels
      return [] if action_labels.blank?

      matching = action_labels.select { |label| issue.has_label?(label) }
      return [] if matching.empty?

      [ { type: "actionable_labels", details: matching } ]
    end

    def check_merge_conflicts(project, pr_data)
      return [] unless project.auto_fix_merge_conflicts
      return [] unless pr_data
      return [] if pr_data.mergeable.nil? || pr_data.mergeable

      [ { type: "merge_conflicts", details: "PR has merge conflicts" } ]
    end

    # --- Owner approval check ---

    def owner_approved_or_self_authored?(project, reviews, pr_data)
      return true if owner_is_pr_author?(project, pr_data)

      owner_approved_from_reviews?(project, reviews)
    end

    def owner_approved_from_reviews?(project, reviews)
      return false if reviews.nil?

      owner_login = project.owner_reviewer_login
      return false if owner_login.blank?

      owner_reviews = reviews.select { |r| r[:user_login]&.downcase == owner_login.downcase }
      return false if owner_reviews.empty?

      latest = owner_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
      latest[:state] == "APPROVED"
    end

    def owner_is_pr_author?(project, pr_data)
      owner_login = project.owner_reviewer_login
      author_login = pr_data&.user&.login

      return false if owner_login.blank? || author_login.blank?

      owner_login.casecmp?(author_login)
    end

    # --- Review feedback gate for auto-merge ---

    # Returns true when there is no outstanding review feedback that should
    # block auto-merge. Checks the same review signals that detect_ready_triggers
    # would evaluate, so owner approval cannot bypass new findings.
    def no_outstanding_review_feedback?(project, client, issue, reviews)
      last_run = last_completed_run(project, issue)
      unresolved_threads = fetch_unresolved_threads(client, project, issue)

      return false if human_review_thread_triggers(project, unresolved_threads).any?
      return false if check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue).any?
      return false if changes_requested_from_reviews(project, reviews, last_run).any?
      return false if check_conversation_comments(client, project, issue, last_run).any?

      true
    end

    # --- Helpers ---

    def review_bot?(login)
      ProviderSupport.provider_bot_username?(login)
    end

    def extract_actionable_labels(triggers)
      label_trigger = triggers.find { |t| t[:type] == "actionable_labels" }
      return [] unless label_trigger

      label_trigger[:details]
    end

    def bot_user?(login)
      return true if login.blank?

      normalized = login.downcase
      return true if normalized.end_with?("[bot]", "-bot")

      KNOWN_BOT_PREFIXES.any? { |prefix| normalized.start_with?(prefix) }
    end

    def system_generated_comment?(body)
      Activities::CompleteExistingPrRunActivity.agent_update_comment?(body)
    end

    def log_signal_error(signal, project, issue, error)
      logger.warn(
        message: "pr_scanner.signal_check_failed",
        signal: signal,
        project_id: project.id,
        pr_number: issue.github_number,
        error: error.message
      )
    end

    def log_triggers(project, issue, triggers)
      logger.info(
        message: "pr_scanner.triggers_detected",
        project_id: project.id,
        pr_number: issue.github_number,
        triggers: triggers.map { |t| t[:type] }
      )
    end
  end
end
