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
    include Automation::LabelPolicy

    activity_name "ScanPaidPrs"

    MIN_COMMENT_LENGTH = 20
    CI_ACTION_DISPATCH_GRACE_PERIOD = 2.minutes
    DEFAULT_CONSECUTIVE_UNSUCCESSFUL_PR_RUNS = 3
    # Escalation requires the stuck state to persist across this many scan
    # cycles, not a wall-clock duration. Scans only run while Paid is active,
    # so an outage (which produces no scans) can never advance the count and
    # drive a false escalation. The first eligible scan records the observation;
    # each subsequent confirming scan that still finds the PR stuck increments
    # the count until it reaches this threshold.
    REQUIRED_STUCK_CONFIRMATIONS = 2
    # Floor for re-scanning a PR even when GitHub's `updated_at` has not
    # advanced. `updated_at` does not bump for check-run state changes,
    # unanswered bot review requests, or review-goal retry timers — without
    # a time ceiling, PRs waiting on those signals are skipped indefinitely.
    SCAN_STALENESS_MULTIPLIER = 3
    KNOWN_BOT_PREFIXES = %w[dependabot renovate github-actions].freeze
    DEPENDENCY_UPDATE_BOT_AUTHORS = Project::DEPENDENCY_UPDATE_BOT_AUTHORS
    DEPENDABOT_AUTO_MERGE_AUTHORS = DependabotAutoMergeJob::DEPENDABOT_AUTHORS
    REVIEW_BOT_CLEAN_PATTERN = /generated no (?:new )?comments/i
    # Body-only review bots (currently Codex) signal "no findings" by posting
    # an *issue comment* — not a review — with text like
    # "Codex Review: Didn't find any major issues. Hooray!" Match the
    # distinctive phrase rather than the prefix so we are robust to minor
    # wording changes.
    BODY_ONLY_BOT_CLEAN_COMMENT_PATTERN = /didn'?t find any (?:major )?issues/i

    # paid_agent clean reviews include a machine-readable HTML marker in the
    # review body. Once the dedicated paid-code-reviewer bot is registered in
    # PROVIDER_BOT_USERNAMES, we can safely key off both author identity and
    # the marker without matching human-authored text.
    PAID_REVIEW_CLEAN_MARKER = "<!-- paid-review-clean -->"
    PAID_ESCALATED_LABEL = "paid-escalated"
    TRIGGER_TO_FOCUS = {
      "actionable_labels" => "label_action",
      "changes_requested" => "review_feedback",
      "ci_failure" => "ci_fix",
      "conversation_comments" => "conversation",
      "merge_conflicts" => "merge_conflict",
      "paid_agent_review_pending" => "review_feedback",
      "review_bot_comments" => "review_feedback",
      "review_bot_review_pending" => "review_feedback",
      "review_bot_threads" => "review_feedback",
      "review_goal_retry" => "review_feedback",
      "review_threads" => "review_feedback"
    }.freeze
    FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES = %w[
      ci_fix
      review_feedback
      merge_conflict
      conversation
      issue_implementation
      label_action
    ].freeze
    FOCUS_PRIORITY = %w[
      merge_conflict
      ci_fix
      review_feedback
      conversation
      issue_implementation
      label_action
    ].freeze

    # Triggers that bypass the paid_agent_review_pending hard gate.
    # merge_conflicts cannot be deferred — a review of code with conflicts
    # isn't meaningful, and leaving it suppressed lets the PR loop indefinitely
    # while reviews keep failing on un-mergeable code (#2324).
    PASS_THROUGH_TRIGGER_TYPES = %w[merge_conflicts].freeze

    def execute(input)
      @pr_progress_states = {}
      @live_pr_states = {}

      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { prs_to_trigger: [], automation_results: [], project_missing: true } unless project
      return { prs_to_trigger: [], automation_results: [] } unless project.auto_scan_prs
      return { prs_to_trigger: [], automation_results: [] } if project.account.tenant_setting&.auto_continue? == false

      client = if project.respond_to?(:client)
        project.client
      else
        project.github_token&.client
      end
      return { prs_to_trigger: [], automation_results: [], credential_missing: true } unless client
      paid_prs = find_paid_prs(project)
      scanned_prs = paid_prs.reject { |issue| merged_issue?(issue) }

      scanned_count = 0
      unchanged_count = 0
      prs_to_trigger = []
      automation_results = []
      pending_review_states = []
      progress_states = []
      with_periodic_heartbeat("scan_paid_prs", project_id: project_id, pr_count: scanned_prs.size) do
        scanned_prs.each_with_index do |issue, index|
          heartbeat("scan_paid_prs.pr", project_id: project_id, issue_id: issue.id, pr_number: issue.github_number, index: index, total: scanned_prs.size)

          if skip_unchanged_pr?(project, issue)
            if merge_conflict_rescan_needed?(project, issue)
              result = scan_merge_conflict_only(project, client, issue)
              if result && result != :skipped
                scanned_count += 1
                issue.update_column(:last_pr_scan_at, Time.current)
                pending_review_states << pending_review_state(issue, result)
                progress_states << serialized_pr_progress_state(project, issue)
                collect_scan_result(issue, result, prs_to_trigger, automation_results,
                  lifecycle: build_lifecycle_signals(project, issue))
                next
              end
            end
            unchanged_count += 1
            next
          end

          result = scan_pr(project, client, issue)
          lifecycle_signals = build_lifecycle_signals(project, issue)
          next if result == :skipped
          scanned_count += 1
          issue.update_column(:last_pr_scan_at, Time.current)
          pending_review_states << pending_review_state(issue, result)
          progress_states << serialized_pr_progress_state(project, issue)
          collect_scan_result(issue, result, prs_to_trigger, automation_results, lifecycle: lifecycle_signals)
        rescue Temporalio::Error::ApplicationError => e
          raise unless e.type == "RateLimit"

          logger.warn(
            message: "pr_scanner.rate_budget_exhausted_mid_scan",
            project_id: project_id,
            prs_collected: automation_results.size,
            prs_remaining: scanned_prs.size - index - 1
          )
          break
        end
      end

      logger.info(
        message: "pr_scanner.scan_complete",
        project_id: project_id,
        prs_found: paid_prs.size,
        prs_scanned: scanned_count,
        prs_skipped_unchanged: unchanged_count,
        prs_triggered: automation_results.size
      )

      {
        prs_to_trigger: prs_to_trigger,
        automation_results: automation_results,
        pr_issue_ids: paid_prs.map(&:id),
        pending_review_states: pending_review_states.compact,
        pr_progress_states: progress_states
      }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    rescue GithubClient::AuthenticationError => e
      logger.error(
        message: "pr_scanner.auth_error",
        project_id: project_id,
        error: e.message
      )
      raise Temporalio::Error::ApplicationError.new(
        "GitHub authentication failed for project #{project_id}: #{e.message}",
        type: "AuthError"
      )
    end

    private

    def collect_scan_result(issue, result, prs_to_trigger, automation_results, lifecycle:)
      automation_result = Automation::StrategyCoordinator.new(project: issue.project)
        .evaluate_pull_request(
          record: issue,
          metadata: {
            scan: result,
            lifecycle: lifecycle
          },
          strategy_types: %i[auto_continue]
        )

      legacy_trigger = legacy_trigger_payload(issue, result, lifecycle, automation_result)
      prs_to_trigger << legacy_trigger if legacy_trigger

      metadata = {
        issue_id: issue.id,
        pr_number: issue.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        lifecycle_phase: lifecycle&.dig(:phase),
        lifecycle_draft: lifecycle&.dig(:draft),
        owner_reviewer_login: lifecycle&.dig(:owner_reviewer_login)
      }
      metadata.merge!(result.except(:decisions)) if result.is_a?(Hash)

      return if automation_result.decisions.all? { |decision| decision.type == "noop" }

      automation_results << metadata.merge(automation_result.to_h)
    end

    def legacy_trigger_payload(issue, result, lifecycle, automation_result)
      decisions = automation_result.decisions
      escalate = decisions.find { |decision| decision.type == "escalate" }
      return {
        pr_number: issue.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        owner_reviewer_login: escalate.payload[:owner_reviewer_login],
        triggers: [ { type: "escalate_to_owner", details: escalate.payload[:reason], reason_key: escalate.payload[:reason_key] } ]
      } if escalate

      return result if result.is_a?(Hash)

      mark_ready = decisions.find { |decision| decision.type == "mark_ready" }
      return {
        pr_number: issue.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        owner_reviewer_login: mark_ready.payload[:owner_reviewer_login],
        triggers: [ { type: "ready_for_owner" } ]
      } if mark_ready

      merge = decisions.find { |decision| decision.type == "merge" }
      return {
        pr_number: issue.github_number,
        phase: lifecycle&.dig(:phase),
        draft: lifecycle&.dig(:draft),
        triggers: [ { type: "owner_approved" } ]
      } if merge

      nil
    end

    def build_lifecycle_signals(project, issue)
      # Advance the scan-confirmation counter before evaluating the breakers so
      # the gates below reflect this scan's observation. Mutated exactly here,
      # once per PR per scan attempt. ScanPaidPrsActivity re-runs wholesale on a
      # Temporal retry (max_attempts: 3); that can advance the count one extra
      # time for PRs already processed before the failure — an accepted, rare
      # edge case consistent with the scanner's other per-scan writes (e.g.
      # last_pr_scan_at), which at worst escalates a stuck PR one cycle early.
      update_stuck_confirmation!(project, issue)

      progress_state = pr_progress_state(project, issue)
      op_breaker = operational_failure_breaker?(project, issue, progress_state)
      no_progress_stuck = no_progress_stuck?(project, issue, progress_state)
      failure_limit = failure_streak_limit_reached?(project, issue, progress_state)
      retry_escalation = review_goal_retry_limit_requires_escalation?(project, issue, progress_state:)

      reason, reason_key = if op_breaker
        [ operational_failure_reason, Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES ]
      elsif no_progress_stuck && retry_escalation
        [ review_goal_retry_escalation_reason(project, issue, progress_state:), Issue::PR_ESCALATION_REASON_REVIEW_GOAL_RETRY_LIMIT ]
      elsif no_progress_stuck && failure_limit
        [ failure_streak_reason(project, issue, progress_state), Issue::PR_ESCALATION_REASON_FAILURE_STREAK ]
      end

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        phase: issue.pr_review_phase,
        active_run_exists: active_run_exists?(project, issue),
        operational_failure_breaker: op_breaker,
        no_progress_stuck: no_progress_stuck,
        failure_streak_limit_reached: failure_limit,
        review_goal_retry_limit_requires_escalation: retry_escalation,
        owner_reviewer_login: project.owner_reviewer_login,
        escalation_reason: reason,
        escalation_reason_key: reason_key,
        consecutive_unsuccessful_automatic_runs: progress_state.consecutive_unsuccessful_automatic_runs,
        consecutive_operational_failures: progress_state.consecutive_operational_failures,
        last_meaningful_progress_at: progress_state.last_meaningful_progress_at,
        draft: live_pr_draft_state(issue) { issue.pr_review_phase.in?(%w[draft restarted]) }
      }
    end

    def live_pr_draft_state(issue)
      return yield unless live_pr_states.key?(issue.id)

      live_pr_states.dig(issue.id, :draft)
    end

    def live_pr_states
      @live_pr_states ||= {}
    end

    def pending_review_state(issue, result)
      return unless result.is_a?(Hash)

      trigger = Array(result[:triggers]).find do |entry|
        entry[:type] == "review_bot_review_pending" &&
          !entry[:data_incomplete] &&
          (entry[:request_login].present? || Array(entry[:request_logins]).any?)
      end

      {
        issue_id: issue.id,
        pending_review: trigger.present?,
        requested_bot: trigger&.dig(:request_login) || Array(trigger&.dig(:request_logins)).first,
        pr_phase: issue.pr_review_phase
      }.compact
    end

    def find_paid_prs(project)
      candidate_prs = project.issues
        .pull_requests_only
        .auto_continue_active
        .where(github_state: "open")

      labeled_prs = automation_labeled_prs(project, candidate_prs)
      dependabot_prs = if project.auto_merge_dependabot?
        dependabot_auto_merge_prs(candidate_prs)
      else
        candidate_prs.none
      end
      scannable_prs = labeled_prs.or(dependabot_prs)

      trusted_creator_logins = trusted_creator_logins_for(project)
      trusted_prs = if trusted_creator_logins.any?
        scannable_prs.where("LOWER(github_creator_login) IN (?)", trusted_creator_logins).to_a
      else
        []
      end
      untrusted_prs = if trusted_creator_logins.any?
        scannable_prs.where("LOWER(github_creator_login) NOT IN (?)", trusted_creator_logins)
      else
        scannable_prs
      end

      trusted_prs + untrusted_prs.select { |issue| authorized_for_automation_scan?(project, issue) }
    end

    def automation_labeled_prs(project, candidate_prs)
      candidate_prs.where("labels @> ?", [ project.automation_label_name ].to_json)
    end

    def dependabot_auto_merge_prs(candidate_prs)
      candidate_prs.where("LOWER(github_creator_login) IN (?)", DEPENDABOT_AUTO_MERGE_AUTHORS.map(&:downcase))
    end

    def authorized_for_automation_scan?(project, issue)
      return true if project.trusted_github_author?(issue.github_creator_login)
      return true if dependency_update_bot_author?(issue.github_creator_login)
      return true if trusted_user_added_label?(project, issue, project.automation_label_name)

      Rails.logger.warn(
        message: "pr_scanner.untrusted_pr_blocked",
        project_id: project.id,
        issue_id: issue.id,
        pr_number: issue.github_number,
        creator: issue.github_creator_login,
        label: project.automation_label_name
      )
      false
    end

    def trusted_creator_logins_for(project)
      project.trusted_github_author_logins
    end

    def merged_issue?(issue)
      return issue.merged_phase? if issue.respond_to?(:merged_phase?)

      issue.respond_to?(:pr_review_phase) && issue.pr_review_phase == "merged"
    end

    def scan_pr(project, client, issue)
      record_focus_resolution(project, client, issue)

      backfill_review_goal_retry_reset_at!(issue)

      pr_data = nil
      progress_state = nil

      if pr_data.nil?
        check_rate_budget!(client)
        pr_data = fetch_pr_data(client, project, issue)
        return :skipped if pr_data.nil?
      end
      live_pr_states[issue.id] = { draft: pr_data.draft == true }

      progress_state ||= pr_progress_state(
        project,
        issue,
        current_head_sha: pr_head_sha(pr_data),
        current_head_updated_at: pr_head_commit_timestamp(client, project, issue, pr_data)
      )

      retry_needed = review_goal_retry_needed?(project, issue, progress_state:)

      retry_trigger = nil
      if retry_needed
        failed_count = review_goal_consecutive_failure_count(project, issue, progress_state:)
        max_retries = review_goal_max_retries(project)
        retry_trigger = {
          type: "review_goal_retry",
          details: "Retrying failed review-goal run (attempt #{failed_count + 1}/#{max_retries})"
        }
      end

      result = case issue.pr_review_phase
      when "draft", "restarted"
        if maybe_advance_to_ready(project, issue, pr_data)
          scan_ready_pr(project, client, issue, pr_data: pr_data)
        else
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        end
      when "ready"
        if maybe_restart_draft(project, issue, pr_data)
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        else
          scan_ready_pr(project, client, issue, pr_data: pr_data)
        end
      when "escalated"
        if escalation_dismissed?(issue)
          # escalation_dismissed? and escalation_dismissal_details enforce the
          # same conditions against the same memoized progress state, so the
          # details lookup always returns a non-nil string here.
          dismissal_details = escalation_dismissal_details(issue, progress_state:)
          dismiss_escalation_trigger(issue, draft: pr_data.draft == true, details: dismissal_details)
        elsif maybe_restart_draft(project, issue, pr_data)
          scan_draft_pr(project, client, issue, pr_data: pr_data)
        else
          scan_escalated_pr(project, client, issue, pr_data: pr_data)
        end
      end

      merge_retry_trigger(result, retry_trigger, issue)
    end

    def merge_retry_trigger(result, retry_trigger, issue)
      return result unless retry_trigger
      return result if result == :skipped
      return result if issue.pr_review_phase == "escalated"

      if result.is_a?(Hash)
        result[:triggers] = [ retry_trigger ] + (result[:triggers] || [])
        result[:current_review_goal_retry_count] = issue.review_goal_retry_count
        result
      else
        {
          focus: focus_for(issue.project, [ retry_trigger ]),
          issue_id: issue.id,
          pr_number: issue.github_number,
          triggers: [ retry_trigger ],
          phase: issue.pr_review_phase,
          current_review_goal_retry_count: issue.review_goal_retry_count
        }
      end
    end

    def backfill_review_goal_retry_reset_at!(issue)
      return unless issue.pr_review_phase == "restarted"
      return if issue.review_goal_retry_reset_at.present?

      issue.update_column(:review_goal_retry_reset_at, Time.current)
      invalidate_pr_progress_state(issue)
    end

    MAX_CONSECUTIVE_OPERATIONAL_FAILURES = 3

    # --- Draft phase scanning ---

    def draft_review_limit_reached?(project, issue)
      issue.draft_phase? && no_progress_stuck?(project, issue)
    end

    def scan_draft_pr(project, client, issue, pr_data: nil)
      check_rate_budget!(client)

      if third_party_bot_author?(project, issue.github_creator_login)
        return scan_bot_authored_draft_pr(project, client, issue, pr_data: pr_data)
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
        human_triggers = human_review_thread_triggers(project, unresolved_threads, pr_data, issue:, client:)

        if human_triggers.blank?
          reviews = fetch_reviews(client, project, issue)
          review_bot_triggers = check_review_bot_status(reviews, unresolved_threads,
            project: project, last_run: last_run, client: client, issue: issue)
        end
      end

      review_bot_triggers ||= []
      if project.address_all_bot_reviews?
        reviews ||= fetch_reviews(client, project, issue)
        unresolved_threads ||= fetch_unresolved_threads(client, project, issue)
        review_bot_triggers += check_non_enabled_bot_reviews(reviews, unresolved_threads,
          project: project, last_run: last_run, client: client, issue: issue)
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
      paid_agent_rounds_exhausted = reviews && paid_agent_review_rounds_exhausted?(project, reviews, issue)

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
        ci_triggers = ci_failure_triggers_with_retry(checks || [], client: client, project: project, issue: issue)
        all_triggers.concat(ci_triggers)
      end

      # Surface merge_conflicts for restarted PRs so the loop can break out of
      # a stuck review cycle (#2324). True draft PRs are work-in-progress and
      # may carry temporary conflicts, but a "restarted" PR was previously
      # ready and now has a real conflict the owner expects automation to fix.
      if issue.pr_review_phase == "restarted"
        pr_data ||= fetch_pr_data(client, project, issue)
        all_triggers.concat(check_merge_conflicts(project, pr_data))
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

        # Auto-advance when checks were fetched successfully and all known
        # conclusions are green. Repositories with no CI checks should still
        # leave draft after a clean review; nil means the check fetch failed
        # and we must fail closed instead of guessing.
        if !checks.nil? && all_checks_green?(checks)
          # Check non-bot review gates (manual reviewer, ci_action) before advancing.
          reviews ||= fetch_reviews(client, project, issue) # safety: reviews already fetched above
          gate_triggers = non_bot_review_gate_triggers(project, issue, pr_data, reviews, checks)
          if gate_triggers.any?
            all_pending = pending_triggers + sidecar_triggers + gate_triggers
            log_triggers(project, issue, all_pending)
            return draft_trigger_payload(issue, all_pending)
          end

          return ready_for_owner_trigger(issue, sidecar_triggers: sidecar_triggers)
        end

        # CI still pending or checks unavailable — treat as incomplete so
        # last_pr_scan_at is not advanced. GitHub does not bump PR
        # updated_at on check-run state changes, so advancing here would
        # permanently wedge the PR if CI finishes after this scan tick.
        return :skipped
      end

      # Hard gate: when a paid_agent review is pending for this PR, suppress
      # every other actionable trigger in this cycle. The review run locks
      # /workspace, so emitting blocking triggers alongside causes the
      # workflow to enqueue a create_pr follow-up that collides on the same
      # branch (WorktreeConflict). Other triggers (CI, comments, threads)
      # will be re-detected on the next scan after the review posts, when
      # the appropriate follow-up — informed by the new feedback — can run.
      #
      # Exception: merge_conflicts always passes through. A review of code
      # with merge conflicts can't produce meaningful feedback, and
      # suppressing it lets stuck-review loops keep pinning the PR (#2324).
      # The decision-level gate in Automation::Strategies::AutoReview routes
      # to create_pr only when the review isn't actively running, so the
      # workspace stays single-tenant.
      review_pending = pending_review_trigger(pending_triggers + sidecar_triggers)
      passthrough = pass_through_triggers(all_triggers)
      triggers =
        if review_pending
          log_review_pending_gate(project, issue, suppressed: all_triggers - passthrough)
          passthrough + pending_triggers + sidecar_triggers
        else
          all_triggers + pending_triggers + sidecar_triggers
        end

      log_triggers(project, issue, triggers)
      draft_trigger_payload(issue, triggers)
    end

    # Returns the paid_agent_review_pending trigger when present, or nil.
    # Used as a hard gate to suppress create_pr-eligible triggers in the
    # same cycle, since both runs would share /workspace.
    def pending_review_trigger(triggers)
      Array(triggers).find { |t| t[:type] == "paid_agent_review_pending" }
    end

    def pass_through_triggers(triggers)
      Array(triggers).select { |t| PASS_THROUGH_TRIGGER_TYPES.include?(t[:type].to_s) }
    end

    # Emit a structured log when the gate suppresses other actionable
    # triggers so operators can see why a CI failure or thread comment
    # didn't translate into a create_pr follow-up this cycle.
    def log_review_pending_gate(project, issue, suppressed:)
      return if suppressed.empty?

      logger.info(
        message: "pr_scanner.review_pending_gate",
        project_id: project.id,
        issue_id: issue&.id,
        pr_number: issue&.github_number,
        suppressed_trigger_types: Array(suppressed).map { |t| t[:type] }.uniq
      )
    end

    # Bot-authored PRs (Dependabot, Renovate) skip review requirements.
    # CI failures and merge conflicts trigger auto-continue; green CI advances
    # to ready.
    def scan_bot_authored_draft_pr(project, client, issue, pr_data: nil)
      pr_data ||= fetch_pr_data(client, project, issue)
      return :skipped if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      ci_triggers = ci_failure_triggers(checks || [])
      conflict_triggers = check_merge_conflicts(project, pr_data)
      triggers = ci_triggers + conflict_triggers

      if triggers.any?
        log_triggers(project, issue, triggers)
        return draft_trigger_payload(issue, triggers)
      end

      if !checks.nil? && checks.any? && all_checks_green?(checks)
        return ready_for_owner_trigger(issue)
      end

      nil
    end

    # --- Ready phase scanning ---

    def scan_ready_pr(project, client, issue, pr_data:)
      return :skipped if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      mergeable = pr_data && pr_data[:mergeable]
      progress_state = pr_progress_state(project, issue)

      if third_party_bot_author?(project, issue.github_creator_login)
        return scan_bot_authored_ready_pr(
          project,
          client,
          issue,
          pr_data: pr_data,
          checks: checks,
          mergeable: mergeable,
          progress_state: progress_state
        )
      end

      reviews = fetch_reviews(client, project, issue)
      unresolved_threads = fetch_unresolved_threads(client, project, issue)

      if auto_merge_eligible?(project, client, issue,
           pr_data: pr_data, checks: checks, reviews: reviews, unresolved_threads: unresolved_threads)
        return owner_approved_trigger(issue)
      end

      triggers = detect_ready_triggers(project, client, issue,
        pr_data: pr_data, checks: checks, reviews: reviews, unresolved_threads: unresolved_threads)
      return :skipped if triggers.nil?
      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        focus: focus_for(issue.project, triggers),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: "ready",
        labels_to_remove: extract_actionable_labels(triggers),
        current_followup_count: issue.pr_followup_count
      }
    end

    # Bot-authored PRs (Dependabot, Renovate) skip review requirements.
    # Auto-merge is handled by EvaluateDependabotAutoMergeActivity + DependabotAutoMergeJob.
    # This method only detects follow-up triggers (CI failures, merge conflicts, labels).
    def scan_bot_authored_ready_pr(project, client, issue, pr_data:, checks:, mergeable:, progress_state:)
      triggers = cheap_ready_triggers(project, issue, pr_data: pr_data, checks: checks)

      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        focus: focus_for(project, triggers),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: "ready",
        labels_to_remove: extract_actionable_labels(triggers),
        current_followup_count: issue.pr_followup_count
      }
    end

    # Triggers detectable without additional GitHub API calls when checks
    # and pr_data are already in hand. Used as a cheap pre-gate before
    # the more expensive review-thread / comment-fetch path.
    def cheap_ready_triggers(project, issue, pr_data:, checks:)
      ci_failure_triggers(checks || []) +
        check_merge_conflicts(project, pr_data) +
        check_actionable_labels(project, issue)
    end

    def followup_limit_escalation(issue, triggers, progress_state: pr_progress_state(issue.project, issue))
      project = issue.project
      types_summary = triggers.map { |t| t[:type] }.uniq.join(", ")
      streak = progress_state.consecutive_unsuccessful_automatic_runs
      escalate_trigger(issue,
        reason: "Follow-up run limit reached " \
                "(#{streak}/#{project.max_pr_followup_runs}); " \
                "unresolved: #{types_summary}")
    end

    # --- Escalated phase scanning ---

    def scan_escalated_pr(project, client, issue, pr_data: nil)
      pr_data ||= fetch_pr_data(client, project, issue)

      bot_authored = third_party_bot_author?(project, issue.github_creator_login)
      checks = fetch_check_runs(client, project, pr_data) if pr_data.present?
      reviews = fetch_reviews(client, project, issue) if pr_data.present? && !bot_authored
      unresolved_threads = fetch_unresolved_threads(client, project, issue) if pr_data.present?

      # Owner approval on an escalated PR unblocks auto-merge.
      if project.auto_merge_enabled? && pr_data.present?
        if bot_authored
          if auto_merge_eligible_bot?(project, client, issue,
               checks: checks, mergeable: pr_data[:mergeable])
            return owner_approved_trigger(issue)
          end
        else
          if auto_merge_eligible?(project, client, issue,
               pr_data: pr_data, checks: checks, reviews: reviews,
               unresolved_threads: unresolved_threads)
            return owner_approved_trigger(issue)
          end
        end
      end

      triggers = detect_ready_triggers(project, client, issue,
        pr_data: pr_data, checks: checks, reviews: reviews, unresolved_threads: unresolved_threads)
      return :skipped if triggers.nil?
      return nil if triggers.empty?

      log_triggers(project, issue, triggers)

      {
        focus: focus_for(project, triggers),
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
        focus: focus_for(issue.project, triggers),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: issue.pr_review_phase,
        owner_reviewer_login: issue.project.owner_reviewer_login
      }
    end

    def escalate_trigger(issue, reason: "Draft review limit reached", reason_key: Issue::PR_ESCALATION_REASON_FAILURE_STREAK)
      log_triggers(issue.project, issue, [ { type: "escalate_to_owner" } ])

      {
        focus: focus_for(issue.project, [ { type: "escalate_to_owner", details: reason } ]),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "escalate_to_owner", details: reason, reason_key: reason_key } ],
        phase: issue.pr_review_phase,
        current_draft_review_count: issue.draft_review_count,
        owner_reviewer_login: issue.project.owner_reviewer_login
      }
    end

    def dismiss_escalation_trigger(issue, draft:, details:)
      log_triggers(issue.project, issue, [ { type: "dismiss_escalation" } ])

      {
        focus: focus_for(issue.project, [ { type: "dismiss_escalation", details: details } ]),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "dismiss_escalation", details: details } ],
        phase: "escalated",
        draft: draft == true,
        owner_reviewer_login: issue.project.owner_reviewer_login
      }
    end

    def owner_approved_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "owner_approved" } ])

      {
        focus: focus_for(issue.project, [ { type: "owner_approved", details: "Owner approval requirement satisfied" } ]),
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "owner_approved", details: "Owner approval requirement satisfied" } ],
        phase: "ready"
      }
    end

    def draft_trigger_payload(issue, triggers)
      {
        focus: focus_for(issue.project, triggers),
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

      partial_failure = pr_data.nil? || checks.nil? || reviews.nil? || unresolved_threads.nil?

      triggers = []

      triggers.concat(ci_failure_triggers_with_retry(checks || [], client: client, project: project, issue: issue))
      triggers.concat(check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue))
      triggers.concat(check_non_enabled_bot_reviews(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue))
      triggers.concat(human_review_thread_triggers(project, unresolved_threads, pr_data, issue:, client:))
      triggers.concat(check_conversation_comments(client, project, issue, last_run))
      triggers.concat(changes_requested_from_reviews(project, reviews, last_run))
      triggers.concat(check_actionable_labels(project, issue))
      triggers.concat(check_merge_conflicts(project, pr_data))
      triggers.concat(non_bot_review_gate_triggers(project, issue, pr_data, reviews, checks))

      # When a critical signal source failed but we found actionable
      # triggers from other sources, return them so downstream actions
      # are not suppressed. When no triggers were found and some sources
      # were unavailable, return nil to prevent stamping last_pr_scan_at
      # on a potentially incomplete "all clear".
      return nil if triggers.empty? && partial_failure

      # Hard gate: a pending paid_agent review takes precedence over any
      # other actionable trigger for the PR — see scan_draft_pr for rationale.
      # merge_conflicts is the documented exception (#2324): code with
      # conflicts can't be meaningfully reviewed, so we let create_pr
      # address the conflict first.
      review_pending = pending_review_trigger(triggers)
      if review_pending
        passthrough = pass_through_triggers(triggers)
        log_review_pending_gate(project, issue, suppressed: triggers - [ review_pending ] - passthrough)
        return [ review_pending ] + passthrough
      end

      triggers
    end

    def resolve_focus(triggers)
      candidate_focuses = Array(triggers)
        .filter_map { |trigger| TRIGGER_TO_FOCUS[trigger[:type].to_s] }
        .uniq

      FOCUS_PRIORITY.find { |focus| candidate_focuses.include?(focus) } || "general"
    end

    def focus_for(_project, triggers)
      resolve_focus(triggers)
    end

    # Detect when a user converts a ready/escalated PR back to draft on GitHub.
    # Reset counts and transition to "restarted" phase so the scanner treats it
    # like a fresh draft PR. Returns true if the phase was restarted.
    def maybe_restart_draft(project, issue, pr_data)
      return false unless pr_data&.draft

      had_escalated_label = issue.has_label?(PAID_ESCALATED_LABEL)
      reset_at = Time.current
      issue.update!(
        pr_review_phase: "restarted",
        pr_escalation_reason: nil,
        draft_review_count: 0,
        pr_followup_count: 0,
        review_goal_retry_count: 0,
        review_goal_retry_reset_at: reset_at,
        operational_failure_reset_at: reset_at,
        ci_retry_requested_at: nil,
        labels: issue.labels - [ PAID_ESCALATED_LABEL ]
      )

      remove_escalated_label_from_github(project, issue) if had_escalated_label
      invalidate_pr_progress_state(issue)

      logger.info(
        message: "pr_scanner.phase_restarted",
        project_id: project.id,
        pr_number: issue.github_number,
        previous_phase: issue.pr_review_phase_before_last_save
      )

      true
    end

    def escalation_dismissal_details(issue, progress_state:)
      return unless issue.escalated_phase?
      return "Owner dismissed escalation by removing paid-escalated" unless issue.has_label?(PAID_ESCALATED_LABEL)
      return unless issue.pr_escalation_reason == Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES
      return unless progress_state.consecutive_operational_failures.zero?

      "Operational escalation auto-dismissed after failure signals recovered"
    end

    # Strips the paid-escalated label on GitHub when a PR leaves the escalated
    # phase via a draft restart. Without this, the label persists on GitHub and
    # is re-synced into the local labels array, leaving the PR visually flagged
    # as escalated even though automation has already resumed work on it.
    # Best-effort: a removal failure must not abort the restart.
    def remove_escalated_label_from_github(project, issue)
      pull_request_collector(project).remove_label(issue:, label: PAID_ESCALATED_LABEL)
    end

    def escalation_dismissed?(issue)
      return false unless issue.escalated_phase?
      return false if escalation_transition_pending?(issue)
      return true unless issue.has_label?(PAID_ESCALATED_LABEL)
      return false unless issue.pr_escalation_reason == Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES

      pr_progress_state(issue.project, issue).consecutive_operational_failures.zero?
    end

    def escalation_transition_pending?(issue)
      issue.last_pr_scan_at.blank?
    end

    # Detect when a user marks a draft PR as ready on GitHub without going
    # through Paid's MarkPrReadyActivity. Advances the local phase to "ready"
    # so that ready-phase automation (merge-conflict handling, auto-merge,
    # review-goal evaluation) kicks in. Only applies to draft/restarted
    # phases — escalated and merged are intentional local states that should
    # not be overwritten by GitHub draft status alone.
    def maybe_advance_to_ready(project, issue, pr_data)
      return false if pr_data.nil?
      return false if pr_data.draft
      return false unless issue.draft_phase?

      previous_phase = issue.pr_review_phase
      issue.update!(pr_review_phase: "ready")
      invalidate_pr_progress_state(issue)

      logger.info(
        message: "pr_scanner.phase_advanced_to_ready",
        project_id: project.id,
        pr_number: issue.github_number,
        previous_phase: previous_phase
      )

      true
    end

    def skip_unchanged_pr?(project, issue)
      return false unless issue.last_pr_scan_at
      return false if issue.github_updated_at >= issue.last_pr_scan_at
      return false if recently_completed_run?(project, issue)
      return false if scan_age_exceeds_ceiling?(project, issue)

      logger.debug(
        message: "pr_scanner.skipped_unchanged",
        project_id: project.id,
        pr_number: issue.github_number,
        last_pr_scan_at: issue.last_pr_scan_at,
        github_updated_at: issue.github_updated_at
      )

      true
    end

    # Draft/restarted PRs need a time-based rescan floor because they wait on
    # signals that do not bump GitHub's `updated_at` (bot review requests, CI
    # state transitions, review-goal retry timers).
    #
    # Bot-authored ready-phase PRs (e.g. Dependabot) also need periodic
    # re-evaluation: the first scan may stamp `last_pr_scan_at` while CI is
    # still pending, and CI transitions to green do not update the PR's
    # `updated_at` on GitHub. Without this escape hatch the skip-unchanged
    # optimization prevents the scanner from ever reconsidering them.
    #
    # Human-authored ready/escalated PRs face the same problem regardless of
    # auto_merge_mode: CI transitions from pending to green/red, review
    # comments, and merge-conflict onset do not update the PR's `updated_at`
    # on GitHub. Without this escape hatch a PR scanned while CI is pending
    # is permanently skipped, blocking follow-up runs for CI failures, review
    # feedback, or merge conflicts until someone pushes a commit.
    def scan_age_exceeds_ceiling?(project, issue)
      draft_or_restarted = issue.pr_review_phase.in?(%w[draft restarted])
      bot_ready_for_merge = issue.pr_review_phase == "ready" &&
        third_party_bot_author?(project, issue.github_creator_login) &&
        project.auto_merge_dependabot?
      human_ready_or_escalated = issue.pr_review_phase.in?(%w[ready escalated]) &&
        !third_party_bot_author?(project, issue.github_creator_login)

      return false unless draft_or_restarted || bot_ready_for_merge || human_ready_or_escalated

      ceiling = SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
      stale = issue.last_pr_scan_at < ceiling.seconds.ago

      if stale
        logger.info(
          message: "pr_scanner.scan_age_ceiling_exceeded",
          project_id: project.id,
          pr_number: issue.github_number,
          last_pr_scan_at: issue.last_pr_scan_at,
          ceiling_seconds: ceiling
        )
      end

      stale
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
      pr_run_history_scope(project, issue)
        .where("completed_at >= ?", issue.last_pr_scan_at)
        .exists?
    end

    def active_run_exists?(project, issue)
      pr_run_history_scope(project, issue)
        .where(status: AgentRun::UNFINISHED_STATUSES)
        .where(goal: "create_pr")
        .exists?
    end

    def pr_progress_state(project, issue, current_head_sha: nil, current_head_updated_at: nil)
      @pr_progress_states ||= {}
      cache = (@pr_progress_states[issue.id] ||= {})
      cache_key = if current_head_sha.present?
        [ current_head_sha, current_head_updated_at ]
      else
        :default
      end
      cache[cache_key] ||= PullRequests::ProgressState.call(
        project:,
        issue:,
        current_head_sha:,
        current_head_updated_at:
      )
      # Once we know the live PR head SHA, promote that result to the default
      # cache entry so later callers in the same scan don't reuse a stale
      # pre-fetch snapshot. A SHA mismatch alone is enough to prove progress
      # for runs that recorded result_commit_sha; only nil-result runs need the
      # extra head commit timestamp.
      if current_head_sha.present?
        cache[:default] = cache[cache_key]
      end
      cache[cache_key]
    end

    def serialized_pr_progress_state(project, issue)
      progress_state = pr_progress_state(project, issue)

      {
        issue_id: issue.id,
        consecutive_unsuccessful_automatic_runs: progress_state.consecutive_unsuccessful_automatic_runs,
        consecutive_operational_failures: progress_state.consecutive_operational_failures,
        last_meaningful_progress_at: progress_state.last_meaningful_progress_at,
        latest_automatic_run_at: progress_state.latest_automatic_run_at,
        latest_unsuccessful_run_at: progress_state.latest_unsuccessful_run_at,
        latest_unsuccessful_run_goal: progress_state.latest_unsuccessful_run_goal,
        latest_unsuccessful_run_status: progress_state.latest_unsuccessful_run_status
      }
    end

    def invalidate_pr_progress_state(issue)
      @pr_progress_states&.delete(issue.id)
      issue.invalidate_pr_progress_state_cache! if issue.respond_to?(:invalidate_pr_progress_state_cache!)
    end

    def pr_head_sha(pr_data)
      pr_data&.head&.sha
    end

    def pr_head_commit_timestamp(client, project, issue, pr_data)
      fetch_head_commit_date(client, project, issue, pr_data)
    end

    # Returns the failure-streak limit for the gate currently being enforced.
    # Draft-phase checks use max_draft_review_rounds; ready/escalated checks
    # use max_pr_followup_runs. This keeps phase-specific retry semantics
    # intact even though the streak itself is phase-agnostic.
    def pr_failure_limit(project, issue)
      limit = if issue.pr_review_phase.in?(%w[draft restarted])
        project.max_draft_review_rounds
      else
        project.max_pr_followup_runs
      end

      return 0 if limit == 0
      value = limit.to_i
      value.positive? ? value : DEFAULT_CONSECUTIVE_UNSUCCESSFUL_PR_RUNS
    end

    def failure_streak_limit_reached?(project, issue, progress_state = pr_progress_state(project, issue))
      return false unless progress_state.escalation_worthy?(limit: pr_failure_limit(project, issue))
      return false if suppress_failure_streak_for_review_retry?(project, issue, progress_state)

      true
    end

    def failure_streak_reason(project, issue, progress_state = pr_progress_state(project, issue))
      streak = progress_state.consecutive_unsuccessful_automatic_runs

      if progress_state.latest_unsuccessful_review?
        "No meaningful progress after #{streak} consecutive unsuccessful automatic runs (latest run was review)"
      elsif issue.draft_phase?
        "No meaningful progress after #{streak} consecutive unsuccessful automatic runs in the current PR cycle"
      else
        "No meaningful progress after #{streak} consecutive unsuccessful automatic runs"
      end
    end

    def operational_failure_reason
      "No meaningful progress after " \
        "#{MAX_CONSECUTIVE_OPERATIONAL_FAILURES} consecutive provider/infrastructure failures"
    end

    def review_goal_retry_escalation_reason(project, issue, progress_state: nil)
      "Review-goal retry budget exhausted with no meaningful progress " \
        "(#{review_goal_consecutive_failure_count(project, issue, progress_state:)} consecutive failures)"
    end

    def followup_limit_reached?(project, issue, progress_state = pr_progress_state(project, issue))
      return false unless issue.pr_review_phase.in?(%w[ready escalated])
      return false if suppress_followup_limit_for_review_failures?(project, issue, progress_state)

      no_progress_stuck?(project, issue, progress_state)
    end

    def suppress_followup_limit_for_review_failures?(project, issue, progress_state)
      return false unless progress_state.latest_unsuccessful_review?

      !review_goal_retry_limit_requires_escalation?(project, issue, progress_state:)
    end

    # When the newest failed automatic PR run was a paid_agent review-goal run
    # that still has retry budget remaining, let the retry flow continue rather
    # than escalating on the broader unified PR streak. This preserves the
    # single cross-phase streak for true "stuck" PRs while still giving the
    # review-goal retry path a chance to recover first.
    def suppress_failure_streak_for_review_retry?(project, issue, progress_state)
      return false unless progress_state.latest_unsuccessful_review?
      return false unless review_goal_retry_needed?(project, issue, progress_state:)

      !review_goal_retry_limit_requires_escalation?(project, issue, progress_state:)
    end

    # Draft-phase circuit breaker: while the PR is in draft/restarted,
    # apply the draft-phase retry limit to the unified automatic-run
    # failure streak. The streak itself is phase-agnostic; only the
    # limit selection remains phase-specific here.
    def consecutive_draft_failures_breaker?(project, issue)
      issue.draft_phase? && failure_streak_limit_reached?(project, issue)
    end

    # Circuit breaker: if the last N automatic follow-up runs on this PR
    # all failed due to operational issues (provider exhaustion, wall-clock
    # timeout, auth expiry, rate limiting), escalate to the owner. These
    # are infrastructure failures the agent cannot fix by retrying — they
    # indicate a systemic problem (all providers down, quota exceeded, etc.)
    # that requires human intervention.
    #
    # Unlike consecutive_draft_failures_breaker? (draft-phase only, checks
    # for unproductive output), this breaker applies across all phases and
    # checks for infrastructure-class failures specifically. A run that
    # failed due to a code error won't trip this breaker because a retry
    # with different code changes might succeed.
    #
    # Exception: purely transient provider/infra outages (rate limits,
    # circuit-open, provider exhaustion) are excluded from escalation even
    # when they form the entire streak. A human reviewer cannot fix a
    # temporary provider outage — automated retries will succeed once
    # capacity returns. Only escalate when at least one failure in the
    # streak is non-transient (e.g. auth expiry, task-level timeout).
    def operational_failure_breaker?(project, issue, progress_state = pr_progress_state(project, issue))
      return false if issue.escalated_phase?
      return false unless operational_failure_eligible?(progress_state)

      escalation_confirmed?(issue)
    end

    def no_progress_stuck?(project, issue, progress_state = pr_progress_state(project, issue))
      limit = no_progress_stuck_limit(project, issue, progress_state)
      return false if limit <= 0

      progress_state.stuck?(
        limit:,
        confirmations: issue.stuck_confirmation_count.to_i,
        required_confirmations: REQUIRED_STUCK_CONFIRMATIONS
      )
    end

    def no_progress_stuck_limit(project, issue, progress_state)
      if progress_state.latest_unsuccessful_review? &&
          review_goal_retry_limit_requires_escalation?(project, issue, progress_state:)
        return review_goal_max_retries(project)
      end
      return 0 unless failure_streak_limit_reached?(project, issue, progress_state)

      pr_failure_limit(project, issue)
    end

    # Returns true when the latest finished automatic review-goal run in the
    # current cycle ended in a retryable failure status. Only applies when the
    # paid_agent review method is enabled (review-goal runs are how paid_agent
    # posts reviews).
    def review_goal_retry_needed?(project, issue, progress_state: nil)
      return false unless project.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")

      # Don't retry while a review-goal run is already queued or running.
      return false if review_run_in_progress?(project, issue)

      latest_run = latest_finished_automatic_review_run(project, issue, progress_state:)
      return false unless latest_run&.status&.in?(REVIEW_GOAL_RETRYABLE_FAILURE_STATUSES)

      # Don't retry when the run already posted a review on the PR. The agent
      # may fail after posting (e.g. container timeout, spec failure) but the
      # review content is already visible — retrying would post a duplicate.
      return false if latest_run.review_posted_at.present?

      true
    end

    def last_completed_run(project, issue)
      pr_run_history_scope(project, issue)
        .completed
        .order(completed_at: :desc)
        .first
    end

    def completed_focused_runs_for(project, issue)
      pr_run_history_scope(project, issue)
        .where(goal: "create_pr")
        .where.not(focus: "general")
        .completed
        .order(completed_at: :desc)
    end

    def pr_run_history_scope(project, issue)
      project.agent_runs.where(
        "issue_id = :issue_id OR source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
        issue_id: issue.id,
        pr_num: issue.github_number
      )
    end

    def latest_completed_focused_run(project, issue)
      completed_focused_runs_for(project, issue)
        .includes(:quality_metrics)
        .first
    end

    def focus_resolution_pending?(focused_run)
      return false unless focus_resolution_attribution_enabled?(focused_run.focus)

      metric = focused_run.quality_metrics.find { |quality_metric| quality_metric.metric_type == "automated" }
      metric.blank? || !metric.scores.to_h.key?("focus_resolved")
    end

    def focus_resolution_attribution_enabled?(focus)
      FOCUS_RESOLUTION_ATTRIBUTION_FOCUSES.include?(focus.to_s)
    end

    def record_focus_resolution(project, client, issue)
      focused_run = latest_completed_focused_run(project, issue)
      return unless focused_run && focus_resolution_pending?(focused_run)

      score_updates = focus_resolution_scores(project, client, issue, focused_run)
      return if score_updates.nil?

      metric = QualityMetric.find_or_initialize_by(
        agent_run: focused_run,
        metric_type: "automated"
      )
      metric.assign_attributes(
        prompt_version: focused_run.prompt_version,
        feedback_source: "system",
        scores: (metric.scores || {}).merge(score_updates)
      )
      metric.save! if metric.changed?

      composite_score = QualityMetrics::CalculateCompositeScore.call(agent_run: focused_run)
      return unless metric.composite_score != composite_score

      metric.update!(composite_score:)
    end

    def focus_resolution_scores(project, client, issue, focused_run)
      case focused_run.focus
      when "ci_fix"
        ci_focus_resolution_scores(project, client, issue)
      when "review_feedback"
        review_feedback_resolution_scores(project, client, issue, focused_run)
      when "merge_conflict"
        merge_conflict_resolution_scores(project, client, issue)
      when "conversation"
        conversation_resolution_scores(project, client, issue, focused_run)
      when "issue_implementation"
        issue_implementation_resolution_scores(project, client, issue, focused_run)
      when "label_action"
        label_action_resolution_scores(project, issue)
      end
    end

    def ci_focus_resolution_scores(project, client, issue)
      pr_data = fetch_pr_data(client, project, issue)
      return nil if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      return nil if checks.nil? || checks_pending?(checks)

      score = all_checks_green?(checks) ? 1.0 : 0.0
      { "focus_resolved" => score, "ci_passed" => score }
    end

    def review_feedback_resolution_scores(project, client, issue, focused_run)
      pr_data = fetch_pr_data(client, project, issue)
      return nil if pr_data.nil?

      checks = fetch_check_runs(client, project, pr_data)
      return nil if checks.nil?

      reviews = fetch_reviews(client, project, issue)
      return nil if reviews.nil?

      unresolved_threads = fetch_unresolved_threads(client, project, issue)
      return nil if unresolved_threads.nil?

      triggers = []
      triggers.concat(human_review_thread_triggers(project, unresolved_threads, pr_data, issue:, client:))
      triggers.concat(check_review_bot_status(reviews, unresolved_threads,
        project: project, last_run: focused_run, client: client, issue: issue))
      triggers.concat(check_non_enabled_bot_reviews(reviews, unresolved_threads,
        project: project, last_run: focused_run, client: client, issue: issue))
      triggers.concat(changes_requested_from_reviews(project, reviews, focused_run))
      triggers.concat(check_conversation_comments(client, project, issue, focused_run))
      triggers.concat(non_bot_review_gate_triggers(project, issue, pr_data, reviews, checks))

      { "focus_resolved" => triggers.empty? ? 1.0 : 0.0 }
    end

    def merge_conflict_resolution_scores(project, client, issue)
      pr_data = fetch_pr_data(client, project, issue)
      return nil if pr_data.nil? || pr_data.mergeable.nil?

      { "focus_resolved" => pr_data.mergeable ? 1.0 : 0.0 }
    end

    def conversation_resolution_scores(project, client, issue, focused_run)
      triggers = check_conversation_comments(client, project, issue, focused_run)
      { "focus_resolved" => triggers.empty? ? 1.0 : 0.0 }
    end

    def issue_implementation_resolution_scores(project, client, issue, focused_run)
      pr_data = fetch_pr_data(client, project, issue)
      return nil if pr_data.nil? || pr_data.mergeable.nil?

      checks = fetch_check_runs(client, project, pr_data)
      return nil if checks.nil? || checks_pending?(checks)

      unresolved_threads = fetch_unresolved_threads(client, project, issue)
      return nil if unresolved_threads.nil?

      reviews = fetch_reviews(client, project, issue)
      return nil if reviews.nil?

      ci_passed = all_checks_green?(checks) ? 1.0 : 0.0
      resolved = ci_passed == 1.0 &&
        human_review_thread_triggers(project, unresolved_threads, pr_data, issue:, client:).empty? &&
        changes_requested_from_reviews(project, reviews, focused_run).empty? &&
        check_conversation_comments(client, project, issue, focused_run).empty? &&
        check_actionable_labels(project, issue).empty? &&
        check_merge_conflicts(project, pr_data).empty?

      {
        "focus_resolved" => resolved ? 1.0 : 0.0,
        "ci_passed" => ci_passed
      }
    end

    def label_action_resolution_scores(project, issue)
      triggers = check_actionable_labels(project, issue)
      { "focus_resolved" => triggers.empty? ? 1.0 : 0.0 }
    end

    def fetch_pr_data(client, project, issue)
      pull_request_collector(project, client:).fetch_pull_request(issue:)
    end

    # --- CI checks ---

    def fetch_check_runs(client, project, pr_data)
      pull_request_collector(project).fetch_check_runs(pr_data:)
    end

    # Cooldown period after requesting a CI retry. Prevents triggering another
    # retry or agent run while the rerun is still in progress.
    CI_RETRY_COOLDOWN = 30.minutes

    def ci_failure_triggers(checks)
      failed = failed_checks_from(checks)
      return [] if failed.empty?

      [ { type: "ci_failure", details: failed.map { |c| c[:name] } } ]
    end

    # Wraps ci_failure_triggers with transient failure detection and retry.
    # When all failed checks appear transient and no retry has been attempted
    # recently, reruns the failed GitHub Actions jobs and suppresses the
    # ci_failure trigger so no agent run is started.
    def ci_failure_triggers_with_retry(checks, client:, project:, issue:)
      failed_checks = failed_checks_from(checks)
      return [] if failed_checks.empty?

      triggers = [ { type: "ci_failure", details: failed_checks.map { |c| c[:name] } } ]

      return triggers if ci_retry_cooling_down?(issue)
      return triggers unless transient_failures?(failed_checks, client, project)

      attempt_ci_rerun(failed_checks, client, project, issue) ? [] : triggers
    end

    def ci_retry_cooling_down?(issue)
      issue.ci_retry_requested_at.present? &&
        issue.ci_retry_requested_at > CI_RETRY_COOLDOWN.ago
    end

    def failed_checks_from(checks)
      return [] if checks.nil?

      completed = checks.select { |c| c[:conclusion].present? }
      completed.select { |c| %w[failure cancelled timed_out action_required stale].include?(c[:conclusion]) }
    end

    def transient_failures?(failed_checks, client, project)
      Ci::TransientFailure.call(
        checks: failed_checks,
        github_client: client,
        repo: project.full_name
      )
    end

    def attempt_ci_rerun(failed_checks, client, project, issue)
      run_ids = failed_checks.filter_map { |c| Ci::FailureContext.actions_run_id_from_url(c[:details_url]) }.uniq
      return false if run_ids.empty?

      rerun_succeeded = false
      run_ids.each do |run_id|
        client.rerun_workflow_run_failed_jobs(project.full_name, run_id)
        rerun_succeeded = true
      rescue GithubClient::Error => e
        logger.warn(
          message: "pr_scanner.ci_rerun_failed",
          project_id: project.id,
          issue_id: issue.id,
          run_id: run_id,
          error: e.message
        )
      end

      if rerun_succeeded
        issue.update_column(:ci_retry_requested_at, Time.current)
        logger.info(
          message: "pr_scanner.transient_ci_retry_requested",
          project_id: project.id,
          issue_id: issue.id,
          run_ids: run_ids
        )
      end

      rerun_succeeded
    end

    def all_checks_green?(checks)
      return true if checks.empty?

      checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
    end

    def checks_pending?(checks)
      Array(checks).any? do |check|
        %w[queued in_progress pending requested waiting].include?(check[:status]) ||
          check[:conclusion].blank?
      end
    end

    # Returns pending-style triggers when an enabled non-bot review method
    # (manual or ci_action) has not yet been satisfied. These gates prevent
    # the scanner from advancing a PR when a human reviewer or a specific
    # CI action has not approved/completed.
    def non_bot_review_gate_triggers(project, issue, pr_data, reviews, checks)
      return [] unless project.review_enabled?

      triggers = []

      if project.review_method_enabled?("manual")
        reviewer = project.review_method(:manual).reviewer_login
        if reviewer.present? && !manual_reviewer_approved?(reviews, reviewer)
          triggers << { type: "manual_review_pending", reviewer_login: reviewer,
                        details: "Awaiting approval from #{reviewer}" }
        end
      end

      if project.review_method_enabled?("ci_action") && !checks.nil?
        action_name = project.review_method(:ci_action).action_name
        if action_name.present? && !ci_action_review_complete?(project, checks, pr_data)
          dispatch_needed = ci_action_dispatch_required?(issue, checks, action_name)
          triggers << { type: "ci_action_pending", action_name: action_name,
                        dispatch_required: dispatch_needed,
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

    def ci_action_dispatch_required?(issue, checks, action_name)
      return false unless claude_review_action?(action_name)
      return false if ci_action_dispatch_suppressed?(issue)
      return true if checks.nil? || checks.empty?

      checks.none? { |c| c[:name] == action_name.strip }
    end

    def claude_review_action?(action_name)
      action_name.strip == DispatchClaudeReviewActivity::ACTION_NAME
    end

    def ci_action_dispatch_suppressed?(issue)
      issue.ci_action_dispatched_at.present? && issue.ci_action_dispatched_at >= CI_ACTION_DISPATCH_GRACE_PERIOD.ago
    end

    def ci_action_check_skipped_for_fork?(action_name, pr_data)
      claude_review_action?(action_name) && pr_data&.head&.repo&.fork == true
    end

    # --- Review checks ---

    def fetch_unresolved_threads(client, project, issue)
      pull_request_collector(project, client:).fetch_unresolved_threads(issue:)
    end

    # @spec LID-PR-CONFIRM-003
    def human_review_thread_triggers(project, unresolved_threads, pr_data = nil, issue: nil, client: nil)
      return [] if unresolved_threads.nil?
      return [] if planning_pr?(pr_data, issue:, client:, project:)

      trusted_threads = unresolved_threads.select do |thread|
        thread[:comments].any? do |c|
          project.trusted_github_user?(c[:author]) && !bot_user?(c[:author])
        end
      end

      return [] if trusted_threads.empty?

      [ { type: "review_threads", details: "#{trusted_threads.size} unresolved thread(s)" } ]
    end

    # @spec LID-PR-CONFIRM-003
    # Docs-only Planning PRs (RDR-051 phase 4) defer comment-only review
    # feedback; only a formal "Request changes" review should enqueue a
    # follow-up run, so unresolved-thread presence alone must not trigger
    # one here. `changes_requested_from_reviews` remains the trigger.
    def planning_pr?(pr_data, issue:, client:, project:)
      return false unless issue && client
      return false unless Lid::BuildInferenceChecklist.checklist_appended?(pr_data&.body)

      Lid::BuildInferenceChecklist.docs_only_planning_pr?(
        body: pr_data&.body,
        changed_files: client.pull_request_files(project.full_name, issue.github_number)
      )
    rescue GithubClient::Error
      false
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

    # Returns the ordered list of bot logins to attempt for an explicit
    # review-bot review, with the primary provider first. Forwarded into
    # the +review_bot_review_pending+ trigger as +request_logins+ so the
    # workflow can pass the full chain to +RequestReviewActivity+, which
    # falls through to a configured secondary bot when the primary is
    # rate-limited or unavailable. Returns +[]+ when no bot-backed method
    # is enabled. See Project#review_bot_request_chain.
    def review_bot_request_chain(project)
      project.review_bot_request_chain
    end

    # Review-bot logins that post feedback as a single top-level review body
    # rather than as inline review threads. These bots need the body-only
    # anti-loop guard in check_review_bot_status because thread resolution
    # cannot be used to detect "already addressed" state.
    BODY_ONLY_REVIEW_BOT_LOGINS = %w[codex paid_agent]
      .flat_map { |key| RunnerSupport::RUNNER_BOT_USERNAMES.fetch(key, []) }
      .map(&:downcase)
      .to_set
      .freeze

    BODY_ONLY_REVIEW_PROVIDER_KEYS = %w[codex paid_agent].freeze

    def check_review_bot_status(reviews, unresolved_threads, project: nil, last_run: nil, client: nil, issue: nil)
      allowed = allowed_review_bot_logins(project)
      latest = latest_allowed_bot_review(reviews, allowed)
      paid_agent_limit_reached_for_latest_review =
        paid_agent_review_limit_reached_for_review?(project, reviews, latest, issue)

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
        #
        # Emit the full bot chain (primary first, then fallbacks) as
        # +request_logins+ so RequestReviewActivity can fall through to a
        # configured secondary bot when the primary is rate-limited or
        # unavailable. The single +request_login+ field is preserved for
        # in-flight workflow replays whose history pre-dates the chain
        # support — old workflow code reads it without falling back.
        chain = project ? review_bot_request_chain(project) : []
        if chain.any?
          [ { type: "review_bot_review_pending",
            details: "No review bot review found",
            request_login: chain.first,
            request_logins: chain } ]
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
            if paid_agent_limit_reached_for_latest_review
              body_only_exhausted_triggers
            elsif RunnerSupport.runner_bot_username_for?("paid_agent", latest&.dig(:user_login))
              # Emit paid_agent_review_pending alongside the bot triggers so
              # the workflow queues a review run. Without this, the scanner
              # keeps starting create_pr follow-ups that don't touch the
              # reviewed files, and no fresh review ever re-evaluates the
              # code (#1395).
              body_only_pending_triggers + check_paid_agent_review_status(project, issue)
            else
              body_only_pending_triggers
            end
          elsif RunnerSupport.runner_bot_username_for?("paid_agent", latest&.dig(:user_login))
            # Thread-based bot with all bot threads resolved, or body-only
            # review already addressed by a subsequent agent run whose diff
            # touches at least one reviewed file. Treat as effectively clean
            # to avoid re-requesting reviews that would produce no new
            # comments.
            pending_review = check_paid_agent_review_status(project, issue)
            pending_review.presence || []
          else
            []
          end
        end
      when :unknown
        review_bot_thread_triggers(unresolved_threads)
      end
    end

    MAX_REVIEW_GOAL_RETRIES = 3
    REVIEW_GOAL_RETRYABLE_FAILURE_STATUSES = (AgentRun::FAILURE_STATUSES + %w[no_output]).freeze

    # Returns true when paid_agent is the only enabled bot review method,
    # meaning its pending trigger must block draft exit since no other bot
    # can gate the PR.
    def paid_agent_sole_review_method?(project)
      return false unless project&.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")

      bot_methods = project.enabled_review_methods & %w[copilot codex paid_agent]
      bot_methods == %w[paid_agent]
    end

    # Returns a paid_agent_review_pending trigger when no up-to-date completed
    # automatic paid_agent review-goal run exists and the max_review_rounds
    # limit has not been reached. Unfinished automatic review runs keep
    # emitting the pending trigger so the draft-phase gate remains active
    # until the review is actually posted.
    #
    # When the most recent review-goal run ended without producing a usable
    # review (for example failed, timed out, or no_output), re-emits the
    # trigger so the scanner queues a retry — up to max_review_goal_retries
    # (default 3).
    # Returns [] when the retry limit is reached so no more review-goal runs
    # are queued (#1002). Callers separately decide whether that exhaustion
    # should escalate the PR or let another enabled bot continue review gating.
    def check_paid_agent_review_status(project, issue, progress_state: nil)
      return [] unless issue

      progress_state ||= pr_progress_state(project, issue)
      current_cycle_review_runs = attempted_automatic_review_runs(project, issue)
      unfinished_run = current_cycle_review_run_in_progress(project, issue)

      if unfinished_run
        return [ { type: "paid_agent_review_pending",
                 details: "paid_agent review run is still in progress",
                 active_run: true } ]
      end

      return [] if review_goal_retry_limit_reached?(project, issue, progress_state:)

      # When a review-goal retry is already being emitted as an explicit
      # review_goal_retry trigger, suppress the sidecar-only pending trigger
      # for mixed-bot projects so the remaining bot can keep gating the PR.
      # Paid-agent-only projects still need paid_agent_review_pending to block
      # draft exit until the retried review is posted.
      return [] if review_goal_retry_needed?(project, issue, progress_state:) && !paid_agent_sole_review_method?(project)

      # Count all finished review attempts (including failed/timed-out) toward
      # the max_review_rounds limit, but exclude retried runs because retry
      # bookkeeping marks the superseded run as retried before enqueuing its
      # replacement. Counting both would burn two rounds for one logical retry.
      finished_count = current_cycle_review_runs.finished.count
      max_rounds = project.review_method(:paid_agent).max_review_rounds

      if max_rounds.present? && finished_count >= max_rounds.to_i
        return []
      end

      # When review-goal runs finish without a usable review, re-emit the trigger so the
      # scanner queues a retry. The retry cap is enforced by
      # review_goal_retry_limit_reached? which callers check separately
      # to escalate when the cap is hit. This check runs before the
      # #830 "already reviewed" guard so failed/no-output reviews are retried
      # even when the last finished review attempt post-dates the last create_pr.
      # However, when the run already posted a review on the PR, the feedback is
      # visible — retrying would post a duplicate review on every scan cycle.
      latest_finished_run = latest_finished_automatic_review_run(project, issue, progress_state:)
      if latest_finished_run&.status&.in?(REVIEW_GOAL_RETRYABLE_FAILURE_STATUSES) &&
          latest_finished_run.review_posted_at.blank?
        failed_count = review_goal_consecutive_failure_count(project, issue, progress_state:)
        max_retries = review_goal_max_retries(project)
        return [ { type: "paid_agent_review_pending",
                 details: "Retrying unsuccessful review-goal run (attempt #{failed_count + 1}/#{max_retries})" } ]
      end

      # Check whether the most recent finished review-goal run (regardless of
      # success) was attempted after the last create_pr run. If so, the review
      # was already attempted for the current code — don't re-trigger.
      # Previously only checked completed runs, which let timed-out reviews
      # re-trigger on every scan cycle (#830).
      last_review_run = current_cycle_review_runs.finished
        .order(Arel.sql("COALESCE(completed_at, updated_at) DESC")).first
      last_create_pr_run = create_pr_runs_for_current_cycle(
        pr_run_history_scope(project, issue)
          .where(goal: "create_pr")
          .completed,
        issue
      ).order(completed_at: :desc).first

      if last_review_run
        review_timestamp = last_review_run.completed_at || last_review_run.updated_at
        if last_create_pr_run
          return [] if review_timestamp >= last_create_pr_run.completed_at
        else
          # No create_pr has run in the current cycle. A completed review
          # with no subsequent code changes means findings are unaddressed —
          # suppress re-triggering to avoid back-to-back review runs on
          # identical code (#1152). The workflow routes this state to a
          # create_pr follow-up instead.
          return []
        end
      end

      [ { type: "paid_agent_review_pending", details: "No paid_agent review found for PR" } ]
    end

    def runs_for_current_review_cycle(runs, issue)
      return runs unless issue.pr_review_phase == "restarted"

      reset_at = issue.review_goal_retry_reset_at
      return runs unless reset_at

      # Use the earliest known attempt timestamp instead of completion time so
      # a run queued before the restart stays in the old cycle even if it
      # starts or finishes afterward.
      runs.where(review_run_cycle_boundary.gt(reset_at))
    end

    def review_runs_for_current_cycle(review_runs, issue)
      runs_for_current_review_cycle(review_runs, issue)
    end

    def create_pr_runs_for_current_cycle(create_pr_runs, issue)
      runs_for_current_review_cycle(create_pr_runs, issue)
    end

    # Returns true when the number of consecutive unsuccessful automatic
    # paid_agent review-goal runs since the last meaningful PR progress has
    # reached the configurable retry limit. The reset boundary comes from the
    # unified PR progress model, so successful review/create_pr runs, explicit
    # human resets, and newer PR head commits all clear stale failures (#1002).
    def review_goal_retry_limit_reached?(project, issue, progress_state: nil)
      return false unless project&.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")

      review_goal_consecutive_failure_count(project, issue, progress_state:) >= review_goal_max_retries(project)
    end

    # Escalate only when exhausting paid_agent retries leaves no other bot
    # review method that can continue gating the PR. Mixed bot projects should
    # stop retrying paid_agent but keep flowing through the remaining bot.
    def review_goal_retry_limit_requires_escalation?(project, issue, progress_state: nil)
      return false unless review_goal_retry_limit_reached?(project, issue, progress_state:)
      return false if review_run_in_progress?(project, issue)

      (project.enabled_review_methods & %w[copilot codex]).empty?
    end

    def review_run_in_progress?(project, issue)
      current_cycle_review_run_in_progress(project, issue).present?
    end

    def current_cycle_review_run_in_progress(project, issue)
      all_review_runs(project, issue)
        .where(status: AgentRun::UNFINISHED_STATUSES)
        .order(created_at: :desc)
        .first
    end

    def all_review_runs(project, issue)
      review_runs_for_current_cycle(
        pr_run_history_scope(project, issue)
          .where(goal: "review"),
        issue
      )
    end

    def automatic_review_runs(project, issue)
      all_review_runs(project, issue)
        .where(trigger_type: "automatic")
    end

    def attempted_automatic_review_runs(project, issue)
      automatic_review_runs(project, issue)
        .where.not(status: "retried")
    end

    def attempted_automatic_review_runs_since_retry_reset(project, issue, progress_state: nil)
      scope = attempted_automatic_review_runs(project, issue)
      reset_at = review_goal_failure_reset_at(project, issue, progress_state:)
      return scope unless reset_at

      scope.where(review_run_cycle_boundary.gt(reset_at))
    end

    def latest_finished_automatic_review_run(project, issue, progress_state: nil)
      attempted_automatic_review_runs_since_retry_reset(project, issue, progress_state:)
        .finished
        .order(Arel.sql("#{PullRequests::ProgressState::RUN_TIMESTAMP_SQL} DESC, created_at DESC, id DESC"))
        .first
    end

    def review_goal_consecutive_failure_count(project, issue, progress_state: nil)
      consecutive_retryable_review_failures(
        attempted_automatic_review_runs_since_retry_reset(project, issue, progress_state:),
        progress_state: progress_state || pr_progress_state(project, issue)
      )
    end

    def review_goal_failure_reset_at(project, issue, progress_state: nil)
      retry_reset_at = issue.review_goal_retry_reset_at

      [
        retry_reset_at,
        progress_state&.last_meaningful_progress_at
      ].compact.max
    end

    def consecutive_retryable_review_failures(scope, progress_state:, batch_size: PullRequests::ProgressState::RUN_BATCH_SIZE)
      failure_count = 0
      offset = 0
      ordered_scope = scope.finished
        .order(Arel.sql("#{PullRequests::ProgressState::RUN_TIMESTAMP_SQL} DESC, created_at DESC, id DESC"))

      loop do
        batch = ordered_scope
          .limit(batch_size)
          .offset(offset)
          .to_a
        break if batch.empty?

        batch.each do |run|
          run_time = run.completed_at || run.updated_at || run.created_at
          return failure_count if progress_state.last_meaningful_progress_at.present? &&
            run_time.present? &&
            run_time <= progress_state.last_meaningful_progress_at
          return failure_count unless run.status.in?(REVIEW_GOAL_RETRYABLE_FAILURE_STATUSES)
          return failure_count if run.review_posted_at.present?

          failure_count += 1
        end

        break if batch.length < batch_size

        offset += batch_size
      end

      failure_count
    end

    def review_goal_max_retries(project)
      method_config = project.review_method(:paid_agent)
      retries = method_config.max_review_goal_retries
      max_rounds = method_config.max_review_rounds

      effective = retries.present? ? retries.to_i : MAX_REVIEW_GOAL_RETRIES

      if max_rounds.present?
        [ effective, max_rounds.to_i ].min
      else
        effective
      end
    end

    # Returns true when the PR's escalation-eligible stuck state has been
    # confirmed across enough scan cycles. Backed by the persisted
    # stuck_confirmation_count, which is advanced once per scan by
    # update_stuck_confirmation!.
    def escalation_confirmed?(issue)
      issue.stuck_confirmation_count.to_i >= REQUIRED_STUCK_CONFIRMATIONS
    end

    # The escalation-eligible predicate: the PR would be escalated except for
    # the scan-confirmation gate. Either the operational-failure breaker core or
    # the unified failure-streak limit has been reached. Once escalated the PR
    # is no longer eligible (dismissal returns it to a non-escalated phase).
    def escalation_eligible?(project, issue, progress_state)
      return false if issue.escalated_phase?
      # Cheap short-circuit for the common healthy-PR case: with no failures on
      # the books the PR can't be at either limit, so skip the DB-backed limit
      # lookups below (no_progress_stuck_limit queries review-run history).
      return false if progress_state.consecutive_unsuccessful_automatic_runs.zero? &&
        progress_state.consecutive_operational_failures.zero?

      operational_failure_eligible?(progress_state) ||
        no_progress_stuck_limit(project, issue, progress_state) > 0
    end

    def operational_failure_eligible?(progress_state)
      progress_state.consecutive_operational_failures >= MAX_CONSECUTIVE_OPERATIONAL_FAILURES &&
        !progress_state.all_provider_transient_outages?
    end

    # Advances the per-issue scan-confirmation count once per scan. When the PR
    # is escalation-eligible the count increments (each scan re-confirms the
    # stuck state); otherwise it resets to zero. Downtime produces no scans, so
    # the count never advances while Paid is offline.
    def update_stuck_confirmation!(project, issue)
      progress_state = pr_progress_state(project, issue)
      eligible = escalation_eligible?(project, issue, progress_state)
      current = issue.stuck_confirmation_count.to_i
      new_count = eligible ? current + 1 : 0
      return if new_count == current

      issue.update_column(:stuck_confirmation_count, new_count)
      logger.info(
        message: "pr_scanner.stuck_confirmation_updated",
        issue_id: issue.id,
        pr_number: issue.github_number,
        stuck_confirmation_count: new_count,
        escalation_eligible: eligible
      )
    end

    def review_run_cycle_boundary
      agent_runs = AgentRun.arel_table
      Arel::Nodes::Case.new
        .when(agent_runs[:started_at].eq(nil))
        .then(agent_runs[:created_at])
        .else(Arel::Nodes::NamedFunction.new("LEAST", [
          agent_runs[:started_at],
          agent_runs[:created_at]
        ]))
    end

    def body_only_review_bot?(login)
      return false if login.nil?

      BODY_ONLY_REVIEW_BOT_LOGINS.include?(login.downcase)
    end

    def body_only_review_provider_key_for(login)
      return nil if login.blank?

      BODY_ONLY_REVIEW_PROVIDER_KEYS.find do |provider_key|
        RunnerSupport.runner_bot_username_for?(provider_key, login)
      end
    end

    # Returns true when a clean issue comment authored by a body-only review
    # bot (e.g. Codex) can speak authoritatively for the project's review
    # configuration AND is at least as recent as that bot's latest review on
    # this PR.
    #
    # The comment-vs-review timestamp comparison prevents an older "Bravo"
    # comment from masking a newer non-clean review on a subsequent commit.
    # We intentionally do not require the bot's absolute latest issue comment
    # to be clean, because body-only bots can emit later informational
    # comments (for example setup guidance) that do not request PR changes and
    # should not suppress an earlier clean completion signal. The bypass is
    # restricted to projects whose enabled review bots are ALL body-only; in
    # mixed-bot projects (e.g. Codex + Copilot), a clean Codex comment cannot
    # suppress the pending trigger for Copilot.
    def body_only_bot_clean_comment_present?(client, project, issue, latest_review, allowed_bot_logins)
      return false if allowed_bot_logins.nil? || allowed_bot_logins.empty?
      return false unless allowed_bot_logins.subset?(BODY_ONLY_REVIEW_BOT_LOGINS)

      comments = client.recent_issue_comments(project.full_name, issue.github_number)
      bot_comments = comments.select do |c|
        login = c.user&.login&.downcase
        login && allowed_bot_logins.include?(login)
      end
      return false if bot_comments.empty?

      latest_clean_comment = bot_comments
        .select { |c| BODY_ONLY_BOT_CLEAN_COMMENT_PATTERN.match?(c.body.to_s) }
        .max_by { |c| c.created_at || Time.at(0) }
      return false unless latest_clean_comment

      provider_key = body_only_review_provider_key_for(latest_clean_comment.user&.login)
      return false if provider_key.nil?

      latest_review_provider_key = body_only_review_provider_key_for(latest_review&.dig(:user_login))
      return false if latest_review_provider_key && latest_review_provider_key != provider_key

      review_time = latest_review&.dig(:submitted_at)
      comment_time = latest_clean_comment.created_at
      return true if review_time.nil? || comment_time.nil?

      comment_time >= review_time
    rescue GithubClient::Error => e
      log_signal_error("body_only_bot_clean_comment", project, issue, e)
      false
    end

    def body_only_bot_clean_comment_supersedes_review?(client, project, issue, bot_login, latest_review)
      return false unless body_only_review_bot?(bot_login)
      return false if client.nil? || project.nil? || issue.nil?

      provider_key = RunnerSupport.runner_key_for_bot_username(bot_login)
      bot_logins = RunnerSupport.runner_bot_usernames_for(provider_key)
      body_only_bot_clean_comment_present?(client, project, issue, latest_review, bot_logins)
    rescue GithubClient::Error => e
      log_signal_error("non_enabled_body_only_bot_clean_comment", project, issue, e)
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
      return true if head_sha.nil?
      return false if head_sha == reviewed_commit

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
      pull_request_collector(project, client:).fetch_reviews(issue:)
    end

    def changes_requested_from_reviews(project, reviews, last_run)
      return [] if reviews.nil?

      cutoff = last_run&.completed_at

      reviews_by_user = reviews
        .select { |r| project.trusted_github_user?(r[:user_login]) && !bot_user?(r[:user_login]) }
        .select { |r| cutoff.nil? || r[:submitted_at].nil? || r[:submitted_at] > cutoff }
        .group_by { |r| r[:user_login]&.downcase }

      changes_requested = reviews_by_user.values.filter_map do |user_reviews|
        latest_changes_requested = latest_review_for_state(user_reviews, "CHANGES_REQUESTED")
        next unless latest_changes_requested

        latest_approved = latest_review_for_state(user_reviews, "APPROVED")
        next if latest_approved && review_time(latest_approved) > review_time(latest_changes_requested)

        latest_changes_requested
      end

      return [] if changes_requested.empty?

      [ { type: "changes_requested", details: changes_requested.map { |r| r[:user_login] } } ]
    end

    def latest_review_for_state(reviews, state)
      reviews
        .select { |review| review[:state] == state }
        .max_by { |review| review_time(review) }
    end

    def review_time(review)
      review[:submitted_at] || Time.at(0)
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
      return true if bot_author_auto_merge_allowed?(project, pr_data)

      owner_approved_from_reviews?(project, reviews)
    end

    def bot_author_auto_merge_allowed?(project, pr_data)
      return false unless project.auto_merge_bot_authored?

      paid_agent_pr_author?(project, pr_data&.user&.login)
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
    def no_outstanding_review_feedback?(project, client, issue, reviews, checks: nil, pr_data: nil,
      unresolved_threads: nil)
      last_run = last_completed_run(project, issue)
      unresolved_threads ||= fetch_unresolved_threads(client, project, issue)

      return false if human_review_thread_triggers(project, unresolved_threads, pr_data, issue:, client:).any?
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
      return false if non_bot_review_gate_triggers(project, issue, pr_data, reviews, effective_checks).any?
      return false if check_non_enabled_bot_reviews(reviews, unresolved_threads,
        project: project, last_run: last_run, client: client, issue: issue).any?

      true
    end

    # --- Blocking review method completeness gate ---

    # Returns true when every enabled blocking review method has a
    # completion signal. Review methods and their completion criteria:
    #
    #   paid_agent (sole bot method, non-escalated PRs only) — the most
    #     recent finished review-goal run must not be a failure that posted
    #     no review. A failed, unposted run means the required review never
    #     landed, so the gate holds until a run succeeds (or the retry-limit
    #     escalation path releases it by escalating). Outstanding feedback
    #     from a review that *was* posted is still checked by
    #     no_outstanding_review_feedback?.
    #   copilot / codex — checked by no_outstanding_review_feedback?
    #     (review bot status + thread resolution). Not re-checked here.
    #   ci_action — the check run named by action_name must be present
    #     and have a successful conclusion.
    #   manual — at least one trusted non-bot user must have submitted
    #     an APPROVED review (distinct from owner approval, which gates
    #     the merge trigger itself).
    def all_blocking_review_methods_complete?(project, reviews, checks, pr_data: nil, issue: nil)
      return true unless project.review_enabled? && project.wait_for_reviews?

      if issue && paid_agent_review_unposted_failure?(project, issue, reviews)
        return false
      end

      if project.review_method_enabled?("ci_action")
        return false unless ci_action_review_complete?(project, checks, pr_data)
      end

      if project.review_method_enabled?("manual")
        return false unless manual_review_complete?(project, reviews)
      end

      true
    end

    # Returns true when paid_agent is enabled as the SOLE bot review method,
    # the PR is still in a review-gated phase (not escalated), no paid_agent
    # review has been posted, and the most recent finished review-goal run in
    # the current cycle ended in a retryable failure status without posting a
    # review. The PR then never received the required review, so auto-merge
    # must hold until a run succeeds, or until exhausting retries drives the
    # escalation path (which moves the PR to the escalated phase, exempt
    # below). A posted review — clean or not — is left to the existing
    # no_outstanding_review_feedback? path, so this only closes the "review
    # never landed" hole (#3086).
    #
    # Scope is deliberately narrow:
    # - Sole-method only: mixed-bot projects (e.g. copilot + paid_agent) do
    #   NOT escalate on paid_agent exhaustion — the other bot is meant to keep
    #   gating (see review_goal_retry_limit_requires_escalation?). Blocking
    #   here for a mixed project would deadlock with no recovery.
    # - Escalated PRs are exempt: owner approval intentionally unblocks
    #   auto-merge for an escalated PR (see scan_escalated_pr), and the race
    #   this guard prevents (merge firing before escalation confirms) is
    #   already resolved once the PR has escalated.
    def paid_agent_review_unposted_failure?(project, issue, reviews)
      return false if issue.escalated_phase?
      return false unless paid_agent_sole_review_method?(project)
      return false if paid_agent_review_present?(reviews)

      latest_run = latest_finished_automatic_review_run(
        project, issue, progress_state: pr_progress_state(project, issue)
      )
      return false unless latest_run&.status&.in?(REVIEW_GOAL_RETRYABLE_FAILURE_STATUSES)
      return false if latest_run.review_posted_at.present?

      true
    end

    # Returns true when any posted review came from the paid_agent review bot.
    def paid_agent_review_present?(reviews)
      return false if reviews.blank?

      reviews.any? { |review| RunnerSupport.runner_bot_username_for?("paid_agent", review[:user_login]) }
    end

    # ci_action is complete when the configured action_name appears in
    # the check-run list with a "success" conclusion.
    def ci_action_review_complete?(project, checks, pr_data)
      action_name = project.review_method(:ci_action).action_name
      if action_name.blank?
        Rails.logger.warn(message: "reviews.ci_action_missing_action_name", project_id: project.id)
        return false
      end

      return true if ci_action_check_skipped_for_fork?(action_name, pr_data)

      checks.any? { |c| c[:name] == action_name.strip && c[:conclusion] == "success" }
    end

    # Manual review is complete when the configured reviewer_login has
    # submitted an APPROVED review. This aligns with manual_reviewer_approved?
    # (used in detect_ready_triggers) so the same user gates both paths.
    def manual_review_complete?(project, reviews)
      return false if reviews.nil?

      reviewer = project.review_method(:manual).reviewer_login
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
      pull_request_collector(project, client:).fetch_head_commit_date(issue:, pr_data:)
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
        reviewer = project.review_method(:manual).reviewer_login
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
      RunnerSupport.runner_bot_username?(login)
    end

    # Returns the set of bot logins allowed to trigger review runs, or nil
    # when review is disabled (nil means "no filtering" in
    # latest_allowed_bot_review). An empty Set means "no bots enabled" —
    # intentionally different from nil — so latest_allowed_bot_review
    # matches nothing and callers like paid_agent_is_latest_blocker?
    # correctly return false when review is enabled but no bots are
    # configured.
    def allowed_review_bot_logins(project)
      return nil unless project&.review_enabled?

      project.enabled_review_bot_logins.presence || Set.new
    end

    def check_non_enabled_bot_reviews(reviews, unresolved_threads, project:, last_run:, client: nil, issue: nil)
      return [] unless project&.address_all_bot_reviews?

      enabled_logins = project.enabled_review_bot_logins
      all_bot_logins = RunnerSupport.all_bot_usernames
      non_enabled_logins = all_bot_logins - enabled_logins

      return [] if non_enabled_logins.empty?

      non_enabled_reviews = Array(reviews).select do |r|
        non_enabled_logins.include?(r[:user_login]&.downcase)
      end

      if non_enabled_reviews.empty?
        return non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins)
      end

      all_triggers = []
      non_enabled_reviews
        .group_by { |r| provider_key_or_login_for(r[:user_login]) }
        .each_value do |bot_reviews|
          latest = bot_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
          triggers = non_enabled_bot_triggers_for(latest, unresolved_threads, last_run,
            bot_logins: provider_bot_logins_for(latest[:user_login]),
            client: client, project: project, issue: issue)
          all_triggers.concat(triggers)
        end

      all_triggers.concat(non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins)) if all_triggers.empty?

      all_triggers
    end

    def non_enabled_bot_triggers_for(latest, unresolved_threads, last_run, bot_logins:, client: nil, project: nil, issue: nil)
      return [] if latest.nil?

      bot_login = latest[:user_login]&.downcase
      source_provider = RunnerSupport.runner_key_for_bot_username(bot_login)
      if body_only_bot_clean_comment_supersedes_review?(client, project, issue, bot_login, latest)
        return []
      end

      body = latest[:body].to_s
      if REVIEW_BOT_CLEAN_PATTERN.match?(body) || paid_agent_review_clean?(body)
        return []
      end

      thread_triggers = non_enabled_bot_thread_triggers(unresolved_threads, bot_logins, source_provider: source_provider)
      if body_only_review_bot?(bot_login)
        return non_enabled_bot_comment_triggers(source_provider, thread_triggers) if body_only_review_needs_followup?(latest, last_run)
        return non_enabled_bot_comment_triggers(source_provider, thread_triggers) unless review_diff_touches_reviewed_files?(client, project, issue, latest)

        return []
      end

      return non_enabled_bot_comment_triggers(source_provider, thread_triggers, data_incomplete: true) if unresolved_threads.nil?

      return [] if thread_triggers.empty?

      non_enabled_bot_comment_triggers(source_provider, thread_triggers)
    end

    def non_enabled_bot_comment_triggers(source_provider, thread_triggers = [], data_incomplete: false)
      [
        {
          type: "review_bot_comments",
          details: "Non-configured bot review has unaddressed feedback",
          source_provider: source_provider,
          data_incomplete: data_incomplete
        }.compact,
        *thread_triggers
      ]
    end

    def non_enabled_bot_thread_triggers(unresolved_threads, non_enabled_logins, source_provider: nil)
      return [] if unresolved_threads.nil?

      bot_threads = unresolved_threads.select do |thread|
        thread[:comments].any? { |c| non_enabled_logins.include?(c[:author]&.downcase) }
      end

      return [] if bot_threads.empty?

      [ {
        type: "review_bot_threads",
        details: "#{bot_threads.size} unresolved thread(s) from non-configured bot(s)",
        source_provider: source_provider
      }.compact ]
    end

    def paid_agent_clean_review?(review)
      return false unless review.is_a?(Hash)
      return false unless RunnerSupport.runner_bot_username_for?("paid_agent", review[:user_login])

      paid_agent_review_clean?(review[:body])
    end

    def paid_agent_review_clean?(body)
      return false if body.nil?

      body.include?(PAID_REVIEW_CLEAN_MARKER)
    end

    def paid_agent_review_limit_reached_for_review?(project, reviews, review, issue = nil)
      return false unless review.is_a?(Hash)
      return false unless RunnerSupport.runner_bot_username_for?("paid_agent", review[:user_login])

      paid_agent_review_rounds_exhausted?(project, reviews, issue)
    end

    # --- Paid-agent review round limit enforcement ---

    # Returns the configured max_review_rounds for the paid_agent method,
    # or nil when the limit is not set, paid_agent is not enabled, or
    # reviews are globally disabled.
    def paid_agent_max_review_rounds(project)
      return nil unless project.review_enabled?
      return nil unless project.review_method_enabled?("paid_agent")

      raw = project.review_method(:paid_agent).max_review_rounds
      raw.present? ? raw.to_i : nil
    end

    # Counts the number of reviews submitted by the paid_agent bot account
    # on this PR. Each review submission counts as one round regardless of
    # state (APPROVED, COMMENTED, CHANGES_REQUESTED).
    def paid_agent_review_count(reviews, issue = nil)
      return 0 if reviews.nil?

      reviews = paid_agent_reviews_for_current_cycle(reviews, issue)
      paid_agent_logins = RunnerSupport::RUNNER_BOT_USERNAMES.fetch("paid_agent", []).map(&:downcase).to_set
      reviews.count { |r| paid_agent_logins.include?(r[:user_login]&.downcase) }
    end

    # Returns true when the paid_agent review method is enabled and the
    # number of reviews from the bot account on this PR has reached or
    # exceeded the configured max_review_rounds limit.
    def paid_agent_review_rounds_exhausted?(project, reviews, issue = nil)
      max_rounds = paid_agent_max_review_rounds(project)
      return false if max_rounds.nil? || max_rounds <= 0

      paid_agent_review_count(reviews, issue) >= max_rounds
    end

    def paid_agent_reviews_for_current_cycle(reviews, issue)
      return reviews if reviews.nil?

      reset_at = issue&.review_goal_retry_reset_at
      return reviews unless issue&.pr_review_phase == "restarted" && reset_at.present?

      reviews.select do |review|
        submitted_at = review[:submitted_at]
        submitted_at.nil? || submitted_at > reset_at
      end
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
      return false if (pending_triggers + blocking_triggers).any? { |t| t[:source_provider] && t[:source_provider] != "paid_agent" }

      has_non_paid_agent_thread_triggers = blocking_triggers.any? { |t| t[:type] == "review_bot_threads" }
      return false if has_non_paid_agent_thread_triggers

      return false if other_enabled_body_only_bots?(project)

      allowed = allowed_review_bot_logins(project)
      latest = latest_allowed_bot_review(reviews, allowed)
      return false unless latest

      RunnerSupport.runner_bot_username_for?("paid_agent", latest[:user_login])
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
          !RunnerSupport.runner_bot_username_for?("paid_agent", login)
      end
    end

    def provider_bot_logins_for(login)
      provider_key = RunnerSupport.runner_key_for_bot_username(login)
      return RunnerSupport.runner_bot_usernames_for(provider_key) if provider_key.present?

      Set.new([ login&.downcase ].compact)
    end

    def provider_key_or_login_for(login)
      RunnerSupport.runner_key_for_bot_username(login) || login&.downcase
    end

    def extract_actionable_labels(triggers)
      label_trigger = triggers.find { |t| t[:type] == "actionable_labels" }
      return [] unless label_trigger

      label_trigger[:details]
    end

    def bot_user?(login)
      return false if login.blank?

      normalized = login.downcase
      return true if normalized.end_with?("[bot]", "-bot")

      KNOWN_BOT_PREFIXES.any? { |prefix| normalized.start_with?(prefix) }
    end

    # A PR authored by the project's own GitHub App agent bot (e.g.
    # "paid-agents[bot]"). These are Paid-generated PRs, not third-party
    # automation, so they must follow the full review + auto-merge path.
    #
    # Matches only the "[bot]" author login (github_author_login), never the
    # bare app slug ("paid-agents") — the slug is a registerable human GitHub
    # username and must not be treated as the project's agent. Mirrors the
    # author-trust model in Project#trusted_github_author_logins.
    def paid_agent_pr_author?(project, login)
      return false if login.blank?

      agent_login = project.github_author_login
      agent_login.present? && login.casecmp?(agent_login)
    end

    # A PR authored by a third-party automation bot (Dependabot, Renovate,
    # github-actions) whose PRs skip Paid's review/merge flow. Excludes the
    # project's own agent bot — without this, app-backed projects whose agent
    # authors PRs as "paid-agents[bot]" had those PRs routed through the
    # review-skipping Dependabot path and never reviewed or auto-merged.
    def third_party_bot_author?(project, login)
      bot_user?(login) && !paid_agent_pr_author?(project, login)
    end

    def dependency_update_bot_author?(login)
      return false if login.blank?

      DEPENDENCY_UPDATE_BOT_AUTHORS.include?(login.downcase)
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

    # --- Auto-merge strategy delegation ---

    # Evaluates human-authored PR merge eligibility via the AutoMerge
    # strategy. Collects signals from provider data and delegates the
    # decision to {Automation::Strategies::AutoMerge}.
    def auto_merge_eligible?(project, client, issue, pr_data:, checks:, reviews:, unresolved_threads: nil)
      return false unless project.auto_merge_enabled? && pr_data.present?

      owner_approved = owner_approved_or_self_authored?(project, reviews, pr_data)
      checks_green = !checks.nil? && all_checks_green?(checks)
      mergeable = pr_data[:mergeable] == true
      review_feedback_clear = no_outstanding_review_feedback?(
        project, client, issue, reviews, checks: checks, pr_data: pr_data,
        unresolved_threads: unresolved_threads
      )
      blocking_reviews_complete = all_blocking_review_methods_complete?(
        project, reviews, checks, pr_data: pr_data, issue: issue
      )
      reviews_fresh = !review_stale_for_head?(client, project, issue, pr_data, reviews)
      dependencies_resolved = if human_dependency_check_required?(
        owner_approved: owner_approved,
        checks_green: checks_green,
        mergeable: mergeable,
        review_feedback_clear: review_feedback_clear,
        blocking_reviews_complete: blocking_reviews_complete,
        reviews_fresh: reviews_fresh
      )
        dependencies_resolved?(client, project, issue)
      else
        false
      end

      skip_label = issue.has_label?(Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL)

      signals = Automation::Strategies::AutoMerge::Signals.build(
        issue_id: issue.id,
        pr_number: issue.github_number,
        owner_approved: owner_approved,
        checks_green: checks_green,
        mergeable: mergeable,
        review_feedback_clear: review_feedback_clear,
        blocking_reviews_complete: blocking_reviews_complete,
        reviews_fresh: reviews_fresh,
        dependencies_resolved: dependencies_resolved,
        skip_auto_merge: skip_label
      )

      if skip_label
        logger.info(
          message: "pr_scanner.auto_merge_skipped_by_label",
          project_id: project.id,
          pr_number: issue.github_number,
          label: Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL
        )
      end

      evaluate_auto_merge(project, signals)
    end

    # Evaluates bot-authored PR merge eligibility via the AutoMerge
    # strategy. Bot PRs skip owner-approval and review-feedback gates.
    def auto_merge_eligible_bot?(project, client, issue, checks:, mergeable:)
      dependabot_eligible = project.auto_merge_dependabot?
      checks_green = !checks.nil? && checks.any? && all_checks_green?(checks)
      mergeable_signal = mergeable == true
      dependencies_resolved = if bot_dependency_check_required?(
        dependabot_eligible: dependabot_eligible,
        checks_green: checks_green,
        mergeable: mergeable_signal
      )
        dependencies_resolved?(client, project, issue)
      else
        false
      end

      skip_label = issue.has_label?(Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL)

      signals = Automation::Strategies::AutoMerge::Signals.build(
        issue_id: issue.id,
        pr_number: issue.github_number,
        bot_authored: true,
        dependabot_eligible: dependabot_eligible,
        checks_green: checks_green,
        mergeable: mergeable_signal,
        dependencies_resolved: dependencies_resolved,
        skip_auto_merge: skip_label
      )

      if skip_label
        logger.info(
          message: "pr_scanner.auto_merge_skipped_by_label",
          project_id: project.id,
          pr_number: issue.github_number,
          label: Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL
        )
      end

      evaluate_auto_merge(project, signals)
    end

    def human_dependency_check_required?(owner_approved:, checks_green:, mergeable:,
      review_feedback_clear:, blocking_reviews_complete:, reviews_fresh:)
      owner_approved &&
        checks_green &&
        mergeable &&
        review_feedback_clear &&
        blocking_reviews_complete &&
        reviews_fresh
    end

    def bot_dependency_check_required?(dependabot_eligible:, checks_green:, mergeable:)
      dependabot_eligible &&
        checks_green &&
        mergeable
    end

    def dependencies_resolved?(client, project, issue)
      local_deps, cross_deps = Issues::ParseDependencies.extract(
        body: issue.body,
        comments: dependency_comment_bodies(client, project, issue)
      )

      return true if local_deps.empty? && cross_deps.empty?

      same_repo = [ project.owner.downcase, project.repo.downcase ]
      same_repo_numbers = cross_deps.each_with_object(Set.new) do |((owner, repo, number), _), numbers|
        return false if [ owner, repo ] != same_repo

        numbers << number
      end

      (local_deps.keys.to_set | same_repo_numbers).all? do |number|
        dependency_resolved?(client, project, number)
      end
    rescue GithubClient::Error => e
      log_signal_error("dependencies_resolved", project, issue, e)
      false
    end

    def dependency_comment_bodies(client, project, issue)
      pull_request_collector(project, client:).dependency_comment_bodies(issue:)
    end

    def dependency_resolved?(client, project, number)
      pull_request_collector(project, client:).dependency_resolved?(number:)
    end

    def evaluate_auto_merge(project, signals)
      context = Automation::Context.build(
        record: nil,
        project: project,
        metadata: { Automation::Strategies::AutoMerge::SIGNALS_KEY => signals }
      )
      result = Automation::StrategyCoordinator.new(project: project)
        .evaluate(context:, strategy_types: %i[auto_merge])
      result.decisions.any? { |d| d.type == "merge" }
    end

    def pull_request_collector(project, client: nil)
      @pull_request_collectors ||= {}
      @pull_request_collectors[project.id] ||= Automation::Signals::PullRequestCollector.new(
        providers: Automation::Signals::ProviderContext.for(project, client: client || project.client),
        client: client || project.client,
        logger: logger
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
