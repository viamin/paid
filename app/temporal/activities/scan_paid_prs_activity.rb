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

    # paid_agent clean reviews include a machine-readable HTML marker in the
    # review body. Once the dedicated paid-code-reviewer bot is registered in
    # PROVIDER_BOT_USERNAMES, we can safely key off both author identity and
    # the marker without matching human-authored text.
    PAID_REVIEW_CLEAN_MARKER = "<!-- paid-review-clean -->"

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { prs_to_trigger: [], project_missing: true } unless project
      return { prs_to_trigger: [] } unless project.auto_scan_prs

      client = project.github_token.client
      paid_prs = find_paid_prs(project)

      scanned_count = 0
      unchanged_count = 0
      prs_to_trigger = []
      paid_prs.each do |issue|
        if skip_unchanged_pr?(project, issue)
          if merge_conflict_rescan_needed?(project, issue)
            result = scan_merge_conflict_only(project, client, issue)
            if result && result != :skipped
              scanned_count += 1
              issue.update_column(:last_pr_scan_at, Time.current)
              prs_to_trigger << result
              next
            end
          end
          unchanged_count += 1
          next
        end

        result = scan_pr(project, client, issue)
        # Only count as scanned when the scan actually completed — scan_pr
        # returns :skipped when short-circuited (active run exists) or when
        # API failures prevented full evaluation.
        next if result == :skipped
        scanned_count += 1
        issue.update_column(:last_pr_scan_at, Time.current)
        prs_to_trigger << result if result
      rescue Temporalio::Error::ApplicationError => e
        raise unless e.type == "RateLimit"

        logger.warn(
          message: "pr_scanner.rate_budget_exhausted_mid_scan",
          project_id: project_id,
          prs_collected: prs_to_trigger.size,
          prs_remaining: paid_prs.size - paid_prs.index(issue) - 1
        )
        break
      end

      logger.info(
        message: "pr_scanner.scan_complete",
        project_id: project_id,
        prs_found: paid_prs.size,
        prs_scanned: scanned_count,
        prs_skipped_unchanged: unchanged_count,
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
      return :skipped if active_run_exists?(project, issue)

      case issue.pr_review_phase
      when "draft", "restarted"
        # Rate budget checked inside scan_draft_pr, after non-API early exits
        scan_draft_pr(project, client, issue)
      when "ready"
        check_rate_budget!(client)
        pr_data = fetch_pr_data(client, project, issue)
        if maybe_restart_draft(project, issue, pr_data)
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        else
          scan_ready_pr(project, client, issue, pr_data: pr_data)
        end
      when "escalated"
        check_rate_budget!(client)
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

      check_rate_budget!(client)

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

      review_bot_triggers ||= []
      if project.address_all_bot_reviews?
        reviews ||= fetch_reviews(client, project, issue)
        review_bot_triggers += check_non_enabled_bot_reviews(reviews, unresolved_threads,
          project: project, last_run: last_run)
      end

      # review_bot_review_pending gates draft advancement (the PR must have a
      # clean review-bot review before it can leave draft).
      # paid_agent_review_pending is normally a non-blocking sidecar that
      # signals the workflow to start a review run without preventing
      # ready_for_owner.  However, when paid_agent is the *only* enabled
      # review method there is no other bot that can gate draft exit, so
      # paid_agent_review_pending must block advancement just like
      # review_bot_review_pending does for copilot/codex.
      paid_agent_sole_reviewer = paid_agent_sole_review_method?(project)
      pending_triggers = (review_bot_triggers || []).select { |t| t[:type] == "review_bot_review_pending" }
      sidecar_triggers = (review_bot_triggers || []).select { |t| t[:type] == "paid_agent_review_pending" }

      if paid_agent_sole_reviewer && sidecar_triggers.any?
        pending_triggers.concat(sidecar_triggers)
        sidecar_triggers = []
      end

      blocking_triggers = (review_bot_triggers || []).reject { |t|
        t[:type] == "review_bot_review_pending" || t[:type] == "paid_agent_review_pending"
      }
      paid_agent_rounds_exhausted = reviews && paid_agent_review_rounds_exhausted?(project, reviews)

      # A clean final paid_agent review should still allow the PR to advance.
      # Only escalate when the latest blocking review is from paid_agent and the
      # configured round budget means another review cycle cannot be requested.
      # In mixed-method projects, non-paid_agent bot triggers (e.g. Copilot
      # unresolved-thread triggers) must not cause escalation — those bots can
      # still make progress within their own review cycle.  Skip escalation
      # when any trigger carries data_incomplete (thread data unavailable due
      # to a transient API failure or the skip-comment path).
      data_incomplete = (review_bot_triggers || []).any? { |t| t[:data_incomplete] }
      if paid_agent_rounds_exhausted && !data_incomplete && paid_agent_is_latest_blocker?(project, reviews, pending_triggers, blocking_triggers)
        return escalate_trigger(issue, reason: paid_agent_limit_reason(project))
      end

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
        # Return :skipped so the caller knows the scan was incomplete and
        # should not update last_pr_scan_at.
        return :skipped if pr_data.nil?
        return :skipped if reviews.nil?

        # A draft PR is only ready to leave draft after the latest review-bot
        # review is explicitly clean. Resolved threads alone are not enough.
        if pending_triggers.any?
          triggers = pending_triggers + sidecar_triggers
          log_triggers(project, issue, triggers)
          return draft_trigger_payload(issue, triggers)
        end

        # Only auto-advance when we have at least one check and all conclusions are green.
        # all_checks_green? implicitly rejects nil conclusions (pending checks),
        # and only after a clean review-bot review is present.
        if checks.present? && all_checks_green?(checks)
          # Check non-bot review gates (manual reviewer, ci_action) before advancing.
          reviews ||= fetch_reviews(client, project, issue) # safety: reviews already fetched above
          gate_triggers = non_bot_review_gate_triggers(project, reviews, checks)
          if gate_triggers.any?
            all_pending = pending_triggers + sidecar_triggers + gate_triggers
            log_triggers(project, issue, all_pending)
            return draft_trigger_payload(issue, all_pending)
          end

          return ready_for_owner_trigger(issue, sidecar_triggers: sidecar_triggers)
        end

        return nil # CI still pending or checks unavailable
      end

      # Re-add pending triggers so the workflow can request the review.
      all_triggers.concat(pending_triggers)
      all_triggers.concat(sidecar_triggers)

      triggers = all_triggers
      log_triggers(project, issue, triggers)
      draft_trigger_payload(issue, triggers)
    end

    # --- Ready phase scanning ---

    def scan_ready_pr(project, client, issue, pr_data:)
      return :skipped if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      reviews = fetch_reviews(client, project, issue)
      mergeable = pr_data && pr_data[:mergeable]

      if project.auto_merge_enabled? &&
          pr_data.present? &&
          owner_approved_or_self_authored?(project, reviews, pr_data) &&
          checks.present? &&
          all_checks_green?(checks) &&
          mergeable == true &&
          no_outstanding_review_feedback?(project, client, issue, reviews, checks: checks) &&
          all_blocking_review_methods_complete?(project, reviews, checks) &&
          !review_stale_for_head?(client, project, issue, pr_data, reviews)
        return owner_approved_trigger(issue)
      end

      return nil if followup_limit_reached?(project, issue)

      triggers = detect_ready_triggers(project, client, issue,
        pr_data: pr_data, checks: checks, reviews: reviews)
      return :skipped if triggers.nil?
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

    DISMISS_ESCALATION_LABEL = "paid-dismiss-escalation"

    def scan_escalated_pr(project, client, issue, pr_data: nil)
      pr_data ||= fetch_pr_data(client, project, issue)

      # Owner can dismiss escalation by adding the dismiss label.
      if issue.has_label?(DISMISS_ESCALATION_LABEL)
        return dismiss_escalation_trigger(issue)
      end

      # Owner approval on an escalated PR unblocks auto-merge.
      if project.auto_merge_enabled? && pr_data.present?
        checks = fetch_check_runs(client, project, pr_data)
        reviews = fetch_reviews(client, project, issue)
        mergeable = pr_data[:mergeable]

        if owner_approved_or_self_authored?(project, reviews, pr_data) &&
            checks.present? &&
            all_checks_green?(checks) &&
            mergeable == true &&
            no_outstanding_review_feedback?(project, client, issue, reviews, checks: checks) &&
            all_blocking_review_methods_complete?(project, reviews, checks) &&
            !review_stale_for_head?(client, project, issue, pr_data, reviews)
          return owner_approved_trigger(issue)
        end
      end

      return nil if followup_limit_reached?(project, issue)

      triggers = detect_ready_triggers(project, client, issue, pr_data: pr_data)
      return :skipped if triggers.nil?
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

    def ready_for_owner_trigger(issue, sidecar_triggers: [])
      triggers = [ { type: "ready_for_owner", details: "CI green, review bots clean" } ] + sidecar_triggers
      log_triggers(issue.project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
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

    def dismiss_escalation_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "dismiss_escalation" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "dismiss_escalation", details: "Owner dismissed escalation via label" } ],
        phase: "escalated",
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

    # Returns an array of trigger hashes, or nil when critical API
    # fetches failed *and* no actionable triggers were found — callers
    # use nil to avoid stamping last_pr_scan_at on an incomplete scan.
    #
    # Partial API failures no longer suppress the entire result: triggers
    # that can be evaluated without the failed endpoint (CI failures,
    # actionable labels, merge conflicts, etc.) are still returned. Only
    # when no triggers are found despite missing signal sources do we
    # return nil to prevent a false "all clear".
    def detect_ready_triggers(project, client, issue, pr_data: nil, checks: nil, reviews: nil,
      unresolved_threads: nil)
      last_run = last_completed_run(project, issue)
      pr_data ||= fetch_pr_data(client, project, issue)
      checks ||= fetch_check_runs(client, project, pr_data)
      reviews ||= fetch_reviews(client, project, issue)
      unresolved_threads ||= fetch_unresolved_threads(client, project, issue)

      partial_failure = pr_data.nil? || reviews.nil? || unresolved_threads.nil?

      triggers = []

      triggers.concat(ci_failure_triggers(checks))
      triggers.concat(check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue))
      triggers.concat(check_non_enabled_bot_reviews(reviews, unresolved_threads,
        project: project, last_run: last_run))
      triggers.concat(human_review_thread_triggers(project, unresolved_threads))
      triggers.concat(check_conversation_comments(client, project, issue, last_run))
      triggers.concat(changes_requested_from_reviews(project, reviews, last_run))
      triggers.concat(check_actionable_labels(project, issue))
      triggers.concat(check_merge_conflicts(project, pr_data))
      triggers.concat(non_bot_review_gate_triggers(project, reviews, checks))

      # When a critical signal source failed but we found actionable
      # triggers from other sources, return them so downstream actions
      # are not suppressed. When no triggers were found and some sources
      # were unavailable, return nil to prevent stamping last_pr_scan_at
      # on a potentially incomplete "all clear".
      return nil if triggers.empty? && partial_failure

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

    def skip_unchanged_pr?(project, issue)
      return false unless issue.last_pr_scan_at
      return false if issue.github_updated_at >= issue.last_pr_scan_at
      return false if recently_completed_run?(project, issue)

      logger.debug(
        message: "pr_scanner.skipped_unchanged",
        project_id: project.id,
        pr_number: issue.github_number,
        last_pr_scan_at: issue.last_pr_scan_at,
        github_updated_at: issue.github_updated_at
      )

      true
    end

    def merge_conflict_rescan_needed?(project, issue)
      project.auto_fix_merge_conflicts &&
        issue.pr_review_phase.in?(%w[ready escalated]) &&
        !followup_limit_reached?(project, issue)
    end

    def scan_merge_conflict_only(project, client, issue)
      return :skipped if active_run_exists?(project, issue)

      check_rate_budget!(client)
      pr_data = fetch_pr_data(client, project, issue)
      return :skipped if pr_data.nil?

      triggers = check_merge_conflicts(project, pr_data)
      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: issue.pr_review_phase,
        labels_to_remove: [],
        current_followup_count: issue.pr_followup_count
      }
    end

    def recently_completed_run?(project, issue)
      project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .or(project.agent_runs.where(pull_request_number: issue.github_number))
        .where("completed_at >= ?", issue.last_pr_scan_at)
        .exists?
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
    # this PR all ended without producing any output, stop requeueing
    # to prevent infinite retry loops. A run is "unproductive" if it
    # finished as no_output (completed with zero commits), or if it
    # failed/cancelled/timed out with zero iterations. Runs that did
    # real work before failing don't trip the breaker. Scoped to
    # automatic create_pr runs so that manual runs or review-phase
    # followups don't trip the breaker.
    #
    # The draft_review_count guard ensures we only consider runs from the
    # current draft phase. maybe_restart_draft resets draft_review_count
    # to 0, so older non-draft failures can't trip the breaker when a PR
    # is converted back to draft.
    def consecutive_draft_failures_breaker?(project, issue)
      return false if issue.draft_review_count < MAX_CONSECUTIVE_DRAFT_FAILURES

      unproductive_statuses = AgentRun::FAILURE_STATUSES + %w[cancelled no_output]

      recent_runs = project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .where(trigger_type: "automatic", goal: "create_pr")
        .finished
        .order(created_at: :desc)
        .limit(MAX_CONSECUTIVE_DRAFT_FAILURES)

      return false if recent_runs.size < MAX_CONSECUTIVE_DRAFT_FAILURES

      recent_runs.all? do |run|
        unproductive_statuses.include?(run.status) && (run.status == "no_output" || run.iterations.to_i.zero?)
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

    # Returns pending-style triggers when an enabled non-bot review method
    # (manual or ci_action) has not yet been satisfied. These gates prevent
    # the scanner from advancing a PR when a human reviewer or a specific
    # CI action has not approved/completed.
    def non_bot_review_gate_triggers(project, reviews, checks)
      return [] unless project.review_enabled?

      triggers = []

      if project.review_method_enabled?("manual")
        reviewer = project.review_method_config("manual")["reviewer_login"]
        if reviewer.present? && !manual_reviewer_approved?(reviews, reviewer)
          triggers << { type: "manual_review_pending", reviewer_login: reviewer,
                        details: "Awaiting approval from #{reviewer}" }
        end
      end

      if project.review_method_enabled?("ci_action")
        action_name = project.review_method_config("ci_action")["action_name"]
        if action_name.present? && !ci_action_succeeded?(checks, action_name)
          triggers << { type: "ci_action_pending", action_name: action_name,
                        details: "Awaiting successful #{action_name} check" }
        end
      end

      triggers
    end

    def manual_reviewer_approved?(reviews, reviewer_login)
      return false if reviews.nil?

      reviewer_reviews = reviews.select { |r| r[:user_login]&.downcase == reviewer_login.strip.downcase }
      return false if reviewer_reviews.empty?

      # Time.at(0) fallback: reviews with nil timestamps sort oldest, so any
      # review with a real timestamp will win. GitHub always populates
      # submitted_at in practice, so this is purely defensive.
      latest = reviewer_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
      latest[:state] == "APPROVED"
    end

    def ci_action_succeeded?(checks, action_name)
      return false if checks.nil? || checks.empty?

      matching = checks.find { |c| c[:name] == action_name.strip }
      matching&.dig(:conclusion) == "success"
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
      return :clean if paid_agent_clean_review?(latest)

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
    BODY_ONLY_REVIEW_BOT_LOGINS = %w[codex paid_agent]
      .flat_map { |key| ProviderSupport::PROVIDER_BOT_USERNAMES.fetch(key, []) }
      .map(&:downcase)
      .to_set
      .freeze

    def check_review_bot_status(reviews, unresolved_threads, project: nil, last_run: nil, client: nil, issue: nil)
      allowed = project&.review_enabled? ? (project.enabled_review_bot_logins.presence || Set.new) : nil
      latest = latest_allowed_bot_review(reviews, allowed)
      paid_agent_limit_reached_for_latest_review =
        paid_agent_review_limit_reached_for_review?(project, reviews, latest)

      # Body-only bots (Codex, paid_agent) can post their CLEAN signal as an issue
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
        clean_review_thread_triggers(unresolved_threads)
      when :no_review
        # Only emit a pending trigger when a requestable review bot is
        # configured. When login is nil — reviews globally disabled, or
        # only non-bot review methods (e.g. manual) are enabled — there is
        # no bot that could satisfy the trigger, so emitting it would wedge
        # the draft scanner in a perpetual "waiting for bot review" state
        # with no path out (handle_review_bot_review_pending skips the
        # RequestReviewActivity call when login is nil).
        #
        # When review_bot_request_login returns a non-paid_agent login (e.g.
        # codex), paid_agent exhaustion must not suppress the request — the
        # other bot can still complete its review cycle. Suppress only when
        # login is nil (paid_agent-only project) and rounds are exhausted;
        # the elsif branch handles that via check_paid_agent_review_status.
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
          # Always keep pending status when thread data is unavailable —
          # regardless of whether paid_agent rounds are exhausted. A
          # data_incomplete marker prevents the escalation check from
          # firing with incomplete information, so a transient
          # thread-fetch failure cannot trigger premature escalation.
          [ { type: "review_bot_review_pending", details: "Latest review bot review was not clean", data_incomplete: true } ]
        else
          bot_thread_triggers = review_bot_thread_triggers(unresolved_threads)
          body_only_pending_triggers = [
            { type: "review_bot_review_pending", details: "Latest review bot review was not clean" },
            { type: "review_bot_comments", details: "Latest review bot review generated comments (body-only)" }
          ]
          body_only_exhausted_triggers = [
            { type: "review_bot_comments", details: "Latest review bot review generated comments (body-only)" }
          ]
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
            paid_agent_limit_reached_for_latest_review ? body_only_exhausted_triggers : body_only_pending_triggers
          elsif body_only_review_bot?(latest&.dig(:user_login)) &&
              !review_diff_touches_reviewed_files?(client, project, issue, latest)
            # Body-only bot whose review pre-dates the last agent run
            # (timestamp guard passed), but the interceding diff did not
            # touch any file mentioned in the review's inline comments.
            # Treat as still-unaddressed to prevent unrelated changes
            # (e.g. a CI schema fix) from clearing review findings.
            paid_agent_limit_reached_for_latest_review ? body_only_exhausted_triggers : body_only_pending_triggers
          else
            # Thread-based bot with all bot threads resolved, or body-only
            # review already addressed by a subsequent agent run whose diff
            # touches at least one reviewed file. Treat as effectively clean
            # to avoid re-requesting reviews that would produce no new
            # comments.
            []
          end
        end
      when :unknown
        review_bot_thread_triggers(unresolved_threads)
      end
    end

    # Returns true when paid_agent is the only enabled bot review method,
    # meaning its pending trigger must block draft exit since no other bot
    # can gate the PR.
    def paid_agent_sole_review_method?(project)
      return false unless project&.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")

      bot_methods = project.enabled_review_methods & %w[copilot codex paid_agent]
      bot_methods == %w[paid_agent]
    end

    # Checks whether a paid_agent review-goal run is needed for this PR.
    # Returns a paid_agent_review_pending trigger when no finished review-goal
    # run exists and the max_review_rounds limit has not been reached. Unfinished
    # review runs keep emitting the pending trigger so the draft-phase gate
    # remains active until the review is actually posted.
    def check_paid_agent_review_status(project, issue)
      return [] unless issue

      pr_number = issue.github_number
      review_runs = project.agent_runs.where(
        source_pull_request_number: pr_number,
        goal: "review"
      )
      attempted_review_runs = review_runs.where.not(status: "retried")
      unfinished_run = review_runs.where(status: AgentRun::UNFINISHED_STATUSES)
        .order(created_at: :desc)
        .first

      # Count all finished review attempts (including failed/timed-out) toward
      # the max_review_rounds limit, but exclude retried runs because retry
      # bookkeeping marks the superseded run as retried before enqueuing its
      # replacement. Counting both would burn two rounds for one logical retry.
      finished_count = attempted_review_runs.finished.count
      max_rounds = project.review_method_config("paid_agent")
        .dig("termination", "max_review_rounds")

      if max_rounds.present? && finished_count >= max_rounds.to_i
        return []
      end

      # Check whether the most recent finished review-goal run (regardless of
      # success) was attempted after the last create_pr run. If so, the review
      # was already attempted for the current code — don't re-trigger.
      # Previously only checked completed runs, which let timed-out reviews
      # re-trigger on every scan cycle (#830).
      last_review_run = attempted_review_runs.finished
        .order(Arel.sql("COALESCE(completed_at, updated_at) DESC")).first
      last_create_pr_run = project.agent_runs
        .where(source_pull_request_number: issue.github_number, goal: "create_pr")
        .completed
        .order(completed_at: :desc)
        .first

      if last_review_run && last_create_pr_run
        review_timestamp = last_review_run.completed_at || last_review_run.updated_at
        return [] if review_timestamp >= last_create_pr_run.completed_at
      end

      details = if unfinished_run
        "paid_agent review run is still in progress"
      else
        "No paid_agent review found for PR"
      end

      [ { type: "paid_agent_review_pending", details: details } ]
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

    # Returns true when the diff between the review's commit and the PR
    # HEAD touches at least one file mentioned in the review's inline
    # comments. Falls back to false when inline comments have no file
    # paths, because a body-only review gives us no evidence that a
    # subsequent run addressed the feedback. Comparison fetch failures
    # still fall back to true to avoid wedging on API errors.
    def review_diff_touches_reviewed_files?(client, project, issue, review)
      return true if client.nil? || project.nil? || issue.nil?

      review_id = review[:id]
      reviewed_commit = review[:commit_id]
      return true if review_id.nil? || reviewed_commit.nil?

      # NOTE: The GitHub API does not support filtering review comments by
      # review ID server-side, so we fetch all comments for the PR and
      # filter client-side. This is O(total comments) rather than
      # O(comments on this review), which is fine for typical PR sizes.
      comments = client.pull_request_review_comments(
        project.full_name, issue.github_number
      )
      reviewed_paths = comments
        .select { |c| c[:pull_request_review_id] == review_id }
        .filter_map { |c| c[:path] }
        .to_set
      return false if reviewed_paths.empty?

      # NOTE: pr_data is already fetched in scan_pr, but check_review_bot_status
      # does not receive it. This extra API call is behind multiple guard
      # clauses so it only fires when all other conditions align. Passing
      # pr_data through would avoid this call but adds complexity to
      # check_review_bot_status's already long keyword-arg list.
      #
      # pr_data returns a Sawyer::Resource, so `.head.sha` uses method
      # dispatch. If pull_request is ever changed to return a plain Hash,
      # this would need to switch to dig-style access. The nil guard below
      # keeps this safe in either case.
      pr_data = client.pull_request(project.full_name, issue.github_number)
      head_sha = pr_data&.head&.sha
      return true if head_sha.nil? || head_sha == reviewed_commit

      changed_files = client.compare_changed_files(
        project.full_name, reviewed_commit, head_sha
      )
      changed_files.any? { |f| reviewed_paths.include?(f) }
    rescue GithubClient::Error => e
      log_signal_error("review_diff_check", project, issue, e)
      true
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
      cutoff = last_run&.completed_at
      comments = fetch_conversation_comments(client, project, issue, cutoff)

      relevant = comments.select do |c|
        login = c.user&.login
        next false if bot_user?(login)
        next false unless project.trusted_github_user?(login)
        # Defensive: treat nil created_at as potentially relevant (include it)
        next false if cutoff && c.created_at && c.created_at <= cutoff
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

    # Fetches conversation comments, preferring the lightweight single-page
    # recent_issue_comments call. Falls back to full auto-paginated
    # issue_comments when the returned page is from a multi-page result and
    # the cutoff window extends beyond it (i.e., every comment on the page
    # is newer than the cutoff, meaning older post-cutoff comments may exist
    # on earlier pages).
    def fetch_conversation_comments(client, project, issue, cutoff)
      comments = client.recent_issue_comments(project.full_name, issue.github_number)

      # Treat nil created_at as newer than cutoff (safe: triggers fallback to
      # full pagination rather than silently missing comments).
      if cutoff && comments.multi_page? && comments.any? &&
          comments.all? { |c| c.created_at.nil? || c.created_at > cutoff }
        client.issue_comments(project.full_name, issue.github_number)
      else
        comments
      end
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
    #
    # NOTE: When `checks` is nil (the default), an empty array is passed to
    # non_bot_review_gate_triggers, causing ci_action_succeeded? to return
    # false — conservatively blocking auto-merge if ci_action is enabled.
    # Callers that have check data available should always pass it.
    def no_outstanding_review_feedback?(project, client, issue, reviews, checks: nil)
      last_run = last_completed_run(project, issue)
      unresolved_threads = fetch_unresolved_threads(client, project, issue)

      return false if human_review_thread_triggers(project, unresolved_threads).any?
      return false if check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue).any?
      return false if changes_requested_from_reviews(project, reviews, last_run).any?
      return false if check_conversation_comments(client, project, issue, last_run).any?
      effective_checks = checks || []
      if checks.nil?
        logger.debug(
          message: "pr_scanner.no_outstanding_review_feedback_nil_checks",
          project_id: project.id,
          pr_number: issue.github_number
        )
      end
      return false if non_bot_review_gate_triggers(project, reviews, effective_checks).any?
      return false if check_non_enabled_bot_reviews(reviews, unresolved_threads,
        project: project, last_run: last_run).any?

      true
    end

    # --- Blocking review method completeness gate ---

    # Returns true when every enabled blocking review method has a
    # completion signal. Review methods and their completion criteria:
    #
    #   copilot / codex / paid_agent — checked by no_outstanding_review_feedback?
    #     (review bot status + thread resolution). Not re-checked here.
    #   ci_action — the check run named by action_name must be present
    #     and have a successful conclusion.
    #   manual — at least one trusted non-bot user must have submitted
    #     an APPROVED review (distinct from owner approval, which gates
    #     the merge trigger itself).
    def all_blocking_review_methods_complete?(project, reviews, checks)
      return true unless project.review_enabled? && project.wait_for_reviews?

      if project.review_method_enabled?("ci_action")
        return false unless ci_action_review_complete?(project, checks)
      end

      if project.review_method_enabled?("manual")
        return false unless manual_review_complete?(project, reviews)
      end

      true
    end

    # ci_action is complete when the configured action_name appears in
    # the check-run list with a "success" conclusion.
    def ci_action_review_complete?(project, checks)
      action_name = project.review_method_config("ci_action").to_h["action_name"]
      if action_name.blank?
        Rails.logger.warn(message: "reviews.ci_action_missing_action_name", project_id: project.id)
        return false
      end

      checks.any? { |c| c[:name] == action_name && c[:conclusion] == "success" }
    end

    # Manual review is complete when the configured reviewer_login has
    # submitted an APPROVED review. This aligns with manual_reviewer_approved?
    # (used in detect_ready_triggers) so the same user gates both paths.
    def manual_review_complete?(project, reviews)
      return false if reviews.nil?

      reviewer = project.review_method_config("manual").to_h["reviewer_login"]
      return false if reviewer.blank?

      reviews.any? do |r|
        r[:state] == "APPROVED" &&
          r[:user_login]&.downcase == reviewer.strip.downcase &&
          project.trusted_github_user?(r[:user_login]) &&
          !bot_user?(r[:user_login])
      end
    end

    # --- Stale review detection ---

    # Returns true when any enabled blocking review signal has a stale
    # approval — i.e. the HEAD commit was pushed after the relevant
    # reviewer's latest approval. Each blocking signal is checked
    # individually so that an owner re-approval cannot mask a stale
    # manual review from the configured reviewer.
    def review_stale_for_head?(client, project, issue, pr_data, reviews)
      return false if reviews.nil?

      head_committed_at = fetch_head_commit_date(client, project, issue, pr_data)
      return false if head_committed_at.nil?

      blocking_approval_timestamps(project, reviews).any? do |ts|
        head_committed_at > ts
      end
    end

    def fetch_head_commit_date(client, project, issue, pr_data)
      sha = pr_data&.head&.sha
      return nil if sha.nil?

      commit_data = client.commit(project.full_name, sha)
      commit_data&.commit&.committer&.date
    rescue GithubClient::Error => e
      log_signal_error("fetch_head_commit", project, issue, e)
      nil
    end

    # Returns the latest approval timestamp for each enabled blocking
    # review signal. The owner approval is always included (gated by
    # owner_approved_or_self_authored? upstream). When the manual review
    # method is enabled, the configured reviewer_login's latest approval
    # is checked separately so a fresh owner re-approval cannot mask a
    # stale manual review.
    def blocking_approval_timestamps(project, reviews)
      timestamps = []

      owner_ts = latest_approval_timestamp_for(project, reviews) do |r|
        r[:user_login]&.downcase == project.owner_reviewer_login&.downcase
      end
      timestamps << owner_ts if owner_ts

      if project.review_method_enabled?("manual")
        reviewer = project.review_method_config("manual").to_h["reviewer_login"]
        if reviewer.present?
          manual_ts = latest_approval_timestamp_for(project, reviews) do |r|
            r[:user_login]&.downcase == reviewer.strip.downcase
          end
          timestamps << manual_ts if manual_ts
        end
      end

      timestamps
    end

    # Returns the most recent submitted_at timestamp among APPROVED
    # reviews from trusted non-bot users matching the given block filter.
    def latest_approval_timestamp_for(project, reviews)
      approvals = reviews.select do |r|
        r[:state] == "APPROVED" &&
          project.trusted_github_user?(r[:user_login]) &&
          !bot_user?(r[:user_login]) &&
          yield(r)
      end

      return nil if approvals.empty?

      approvals.filter_map { |r| r[:submitted_at] }.max
    end

    # --- Helpers ---

    def review_bot?(login)
      ProviderSupport.provider_bot_username?(login)
    end

    def check_non_enabled_bot_reviews(reviews, unresolved_threads, project:, last_run:)
      return [] unless project&.address_all_bot_reviews?
      return [] if reviews.nil?

      enabled_logins = project.enabled_review_bot_logins
      all_bot_logins = ProviderSupport.all_bot_usernames
      non_enabled_logins = all_bot_logins - enabled_logins

      return [] if non_enabled_logins.empty?

      non_enabled_reviews = reviews.select do |r|
        non_enabled_logins.include?(r[:user_login]&.downcase)
      end

      return [] if non_enabled_reviews.empty?

      # Group reviews by bot login so each bot is evaluated independently.
      # A newer clean review from one bot must not mask older unresolved
      # feedback from another bot (see P2 review feedback).
      all_triggers = []
      non_enabled_reviews
        .group_by { |r| r[:user_login]&.downcase }
        .each_value do |bot_reviews|
          latest = bot_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
          triggers = non_enabled_bot_triggers_for(latest, unresolved_threads, non_enabled_logins, last_run)
          all_triggers.concat(triggers)
        end

      all_triggers.concat(non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins)) if all_triggers.empty?

      all_triggers
    end

    def non_enabled_bot_triggers_for(latest, unresolved_threads, non_enabled_logins, last_run)
      return [] if latest.nil?

      body = latest[:body].to_s
      if REVIEW_BOT_CLEAN_PATTERN.match?(body) || paid_agent_review_clean?(body)
        return []
      end

      submitted_at = latest[:submitted_at]
      cutoff = last_run&.completed_at
      return [] if submitted_at && cutoff && submitted_at <= cutoff

      thread_triggers = non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins)
      if thread_triggers.any?
        return [
          { type: "review_bot_comments", details: "Non-configured bot review has unaddressed feedback" },
          *thread_triggers
        ]
      end

      [ { type: "review_bot_comments", details: "Non-configured bot review has unaddressed feedback" } ]
    end

    def non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins)
      return [] if unresolved_threads.nil?

      bot_threads = unresolved_threads.select do |thread|
        thread[:comments].any? { |c| non_enabled_logins.include?(c[:author]&.downcase) }
      end

      return [] if bot_threads.empty?

      [ { type: "review_bot_threads", details: "#{bot_threads.size} unresolved thread(s) from non-configured bot(s)" } ]
    end

    def paid_agent_clean_review?(review)
      return false unless review.is_a?(Hash)
      return false unless ProviderSupport.provider_bot_username_for?("paid_agent", review[:user_login])

      paid_agent_review_clean?(review[:body])
    end

    def paid_agent_review_clean?(body)
      return false if body.nil?

      body.include?(PAID_REVIEW_CLEAN_MARKER)
    end

    def paid_agent_review_limit_reached_for_review?(project, reviews, review)
      return false unless review.is_a?(Hash)
      return false unless ProviderSupport.provider_bot_username_for?("paid_agent", review[:user_login])

      paid_agent_review_rounds_exhausted?(project, reviews)
    end

    # --- Paid-agent review round limit enforcement ---

    # Returns the configured max_review_rounds for the paid_agent method,
    # or nil when the limit is not set, paid_agent is not enabled, or
    # reviews are globally disabled.
    def paid_agent_max_review_rounds(project)
      return nil unless project.review_enabled?
      return nil unless project.review_method_enabled?("paid_agent")

      raw = project.review_method_config("paid_agent").dig("termination", "max_review_rounds")
      raw.present? ? raw.to_i : nil
    end

    # Counts the number of reviews submitted by the paid_agent bot account
    # on this PR. Each review submission counts as one round regardless of
    # state (APPROVED, COMMENTED, CHANGES_REQUESTED).
    def paid_agent_review_count(reviews)
      return 0 if reviews.nil?

      paid_agent_logins = ProviderSupport::PROVIDER_BOT_USERNAMES.fetch("paid_agent", []).map(&:downcase).to_set
      reviews.count { |r| paid_agent_logins.include?(r[:user_login]&.downcase) }
    end

    # Returns true when the paid_agent review method is enabled and the
    # number of reviews from the bot account on this PR has reached or
    # exceeded the configured max_review_rounds limit.
    def paid_agent_review_rounds_exhausted?(project, reviews)
      max_rounds = paid_agent_max_review_rounds(project)
      return false if max_rounds.nil? || max_rounds <= 0

      paid_agent_review_count(reviews) >= max_rounds
    end

    def paid_agent_limit_reason(project)
      max_rounds = paid_agent_max_review_rounds(project) || 0
      "the paid_agent review round limit (#{max_rounds} rounds) has been reached"
    end

    # Returns true when the latest review-bot review on this PR is from a
    # paid_agent account AND all present triggers are attributable to
    # paid_agent. In mixed-method projects, non-paid_agent bot triggers
    # (e.g. Copilot unresolved-thread triggers) must not cause escalation
    # when paid_agent's round budget is exhausted but the other bot's
    # cycle can still proceed.
    #
    # paid_agent is a body-only bot — it never creates review threads.
    # Any review_bot_threads trigger must therefore originate from a
    # different bot (e.g. Copilot). When such triggers are present the
    # remaining blocker is not paid_agent-owned, so we return false to
    # allow the other bot's cycle to continue.
    #
    # Codex is also a body-only bot and never produces review_bot_threads
    # triggers. When codex (or any other non-paid_agent body-only bot) is
    # enabled alongside paid_agent, its review cycle can still make
    # progress after paid_agent's rounds are exhausted, so escalation
    # would be premature.
    def paid_agent_is_latest_blocker?(project, reviews, pending_triggers, blocking_triggers)
      return false if reviews.nil?
      return false unless pending_triggers.any? || blocking_triggers.any?

      has_non_paid_agent_thread_triggers = blocking_triggers.any? { |t| t[:type] == "review_bot_threads" }
      return false if has_non_paid_agent_thread_triggers

      return false if other_enabled_body_only_bots?(project)

      allowed = project.enabled_review_bot_logins.presence
      latest = latest_allowed_bot_review(reviews, allowed)
      return false unless latest

      ProviderSupport.provider_bot_username_for?("paid_agent", latest[:user_login])
    end

    # Returns true when the project has an enabled body-only review bot
    # other than paid_agent (e.g. codex). These bots never create review
    # threads, so their presence is invisible to the
    # review_bot_threads check above, but they can still continue the
    # automated review cycle after paid_agent's rounds are exhausted.
    def other_enabled_body_only_bots?(project)
      enabled = project.enabled_review_bot_logins
      return false if enabled.blank?

      enabled.any? do |login|
        BODY_ONLY_REVIEW_BOT_LOGINS.include?(login.downcase) &&
          !ProviderSupport.provider_bot_username_for?("paid_agent", login)
      end
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

    def clean_review_thread_triggers(unresolved_threads)
      return [] if unresolved_threads.nil?

      bot_thread_triggers = review_bot_thread_triggers(unresolved_threads)
      return [] if bot_thread_triggers.empty?

      [
        { type: "review_bot_review_pending", details: "A review bot still has unresolved feedback" },
        { type: "review_bot_comments", details: "A review bot still has unresolved comments" },
        *bot_thread_triggers
      ]
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
