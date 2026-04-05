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
    PASSIVE_REVIEW_GATE_TRIGGER = "review_gate_blocked"

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

    # --- Draft phase scanning ---

    def scan_draft_pr(project, client, issue, pr_data: nil)
      if project.max_draft_review_rounds.positive? &&
          issue.draft_review_count >= project.max_draft_review_rounds
        return escalate_trigger(issue)
      end

      blocking_review_methods = project.blocking_review_methods
      review_based_methods = blocking_review_methods & %w[copilot manual]
      ci_review_required = blocking_review_methods.include?("ci_action")
      skip_comment_signals = project.max_draft_review_rounds.zero?
      unresolved_threads = nil
      human_triggers = []
      required_review_triggers = []
      reviews = nil
      checks = nil

      # Draft exit still requires an explicitly clean bot review even when
      # other draft comment signals are skipped.
      if skip_comment_signals
        reviews = review_based_methods.any? ? fetch_reviews(client, project, issue) : []
        unresolved_threads = fetch_unresolved_threads(client, project, issue) if blocking_review_methods.include?("paid_agent")
        if ci_review_required
          pr_data ||= fetch_pr_data(client, project, issue)
          checks = fetch_check_runs(client, project, pr_data)
        end
        required_review_triggers = check_required_review_methods(project, issue,
          reviews: reviews, unresolved_threads: unresolved_threads, checks: checks)
      else
        # Fetch review threads first; only fetch full reviews when needed.
        unresolved_threads = fetch_unresolved_threads(client, project, issue)
        human_triggers = human_review_thread_triggers(project, unresolved_threads)

        if human_triggers.blank?
          reviews = fetch_reviews(client, project, issue) if review_based_methods.any?
          if ci_review_required
            pr_data ||= fetch_pr_data(client, project, issue)
            checks = fetch_check_runs(client, project, pr_data)
          end
          required_review_triggers = check_required_review_methods(project, issue,
            reviews: reviews, unresolved_threads: unresolved_threads, checks: checks)
        end
      end

      # review_bot_review_pending is non-blocking: it requests a review but
      # should not prevent evaluation of CI, comments, or changes_requested.
      pending_triggers = (required_review_triggers || []).select { |t| t[:type] == "review_bot_review_pending" }
      passive_review_gate_triggers = (required_review_triggers || []).select do |trigger|
        trigger[:type] == PASSIVE_REVIEW_GATE_TRIGGER
      end
      blocking_triggers = (required_review_triggers || []).reject do |trigger|
        [ "review_bot_review_pending", PASSIVE_REVIEW_GATE_TRIGGER ].include?(trigger[:type])
      end
      all_triggers = blocking_triggers + (human_triggers || [])
      append_generic_review_bot_thread_triggers!(all_triggers, unresolved_threads) if blocking_review_methods.include?("paid_agent")

      # Only fetch PR data and check runs if blocking review triggers aren't enough.
      if all_triggers.empty?
        pr_data ||= fetch_pr_data(client, project, issue)
        checks ||= fetch_check_runs(client, project, pr_data)
        ci_triggers = ci_failure_triggers(project, checks || [])
        all_triggers.concat(ci_triggers)
      end

      # Only fetch conversation comments if still no triggers.
      if all_triggers.empty? && !skip_comment_signals
        last_run = last_completed_run(project, issue)
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
        if pending_triggers.any? || passive_review_gate_triggers.any?
          triggers = passive_review_gate_triggers + pending_triggers
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
      all_triggers.concat(passive_review_gate_triggers)
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
          mergeable == true
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

    def escalate_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "escalate_to_owner" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "escalate_to_owner", details: "Draft review limit reached" } ],
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

    def detect_ready_triggers(project, client, issue, pr_data: nil, checks: nil, reviews: nil)
      last_run = last_completed_run(project, issue)
      pr_data ||= fetch_pr_data(client, project, issue)
      checks ||= fetch_check_runs(client, project, pr_data)
      reviews ||= fetch_reviews(client, project, issue)
      blocking_review_methods = project.blocking_review_methods
      triggers = []

      unresolved_threads = fetch_unresolved_threads(client, project, issue)

      triggers.concat(ci_failure_triggers(project, checks))
      triggers.concat(check_required_review_methods(project, issue,
        reviews: reviews, unresolved_threads: unresolved_threads, checks: checks))
      triggers.concat(human_review_thread_triggers(project, unresolved_threads))
      append_generic_review_bot_thread_triggers!(triggers, unresolved_threads) if blocking_review_methods.include?("paid_agent")
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
        .exists?
    end

    def followup_limit_reached?(project, issue)
      issue.pr_followup_count >= project.max_pr_followup_runs
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

    def ci_failure_triggers(project, checks)
      completed = checks.select { |c| c[:conclusion].present? }
      return [] if completed.empty?

      review_action_names = project.ci_review_action_names.map(&:downcase)
      failed = completed.select { |c| %w[failure cancelled timed_out action_required stale].include?(c[:conclusion]) }
        .reject { |c| review_action_names.include?(c[:name].to_s.downcase) }
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

    def review_bot_review_status(reviews, provider_key:)
      return :unknown if reviews.nil?

      bot_reviews = reviews.select { |r| review_bot?(r[:user_login], provider_key: provider_key) }
      return :no_review if bot_reviews.empty?

      latest = bot_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
      REVIEW_BOT_CLEAN_PATTERN.match?(latest[:body]) ? :clean : :has_comments
    end

    def check_review_bot_status(reviews, unresolved_threads, provider_key:)
      status = review_bot_review_status(reviews, provider_key: provider_key)

      case status
      when :clean
        []
      when :no_review
        [ { type: "review_bot_review_pending", details: "No review bot review found" } ]
      when :has_comments
        # When unresolved_threads is nil, threads were either never fetched
        # (e.g. the skip_comment_signals path) or the API call failed. We
        # cannot tell whether bot threads are truly resolved, so treat the
        # status as pending to avoid prematurely advancing the PR.
        if unresolved_threads.nil?
          [ { type: "review_bot_review_pending", details: "Latest review bot review was not clean" } ]
        else
          bot_thread_triggers = review_bot_thread_triggers(unresolved_threads, provider_key: provider_key)
          if bot_thread_triggers.any?
            triggers = [ { type: "review_bot_review_pending", details: "Latest review bot review was not clean" } ]
            triggers << { type: "review_bot_comments", details: "Latest review bot review generated comments" }
            triggers.concat(bot_thread_triggers)
            triggers
          else
            # All bot threads resolved — treat as effectively clean to avoid
            # an infinite loop of requesting reviews that produce no new comments.
            []
          end
        end
      when :unknown
        review_bot_thread_triggers(unresolved_threads, provider_key: provider_key)
      end
    end

    def review_bot_thread_triggers(unresolved_threads, provider_key:)
      return [] if unresolved_threads.nil?

      review_bot_threads = unresolved_threads.select do |thread|
        thread[:comments].any? { |c| review_bot?(c[:author], provider_key: provider_key) }
      end

      return [] if review_bot_threads.empty?

      [ { type: "review_bot_threads", details: "#{review_bot_threads.size} unresolved review bot thread(s)" } ]
    end

    def check_required_review_methods(project, issue, reviews:, unresolved_threads:, checks:)
      triggers = []

      project.blocking_review_methods.each do |method|
        case method
        when "copilot"
          triggers.concat(check_review_bot_status(reviews, unresolved_threads, provider_key: "copilot"))
        when "paid_agent"
          case paid_agent_review_status(project, issue, unresolved_threads)
          when :completed
            next
          when :followup_required
            triggers << { type: "paid_agent_review_threads",
                          details: "Paid review agent left unresolved review comments" }
          when :blocked
            triggers << { type: PASSIVE_REVIEW_GATE_TRIGGER,
                          details: "Paid review agent status could not be verified" }
          else
            triggers << { type: "review_bot_review_pending", details: "Paid review agent has not completed a review yet" }
          end
        when "ci_action"
          pending_actions = pending_ci_review_actions(project, checks)
          next if pending_actions.empty?

          triggers << { type: PASSIVE_REVIEW_GATE_TRIGGER,
                        details: "CI review action still pending: #{pending_actions.join(', ')}" }
        when "manual"
          next if manual_review_completed?(project, issue, reviews)

          triggers << { type: PASSIVE_REVIEW_GATE_TRIGGER, details: "Manual review has not been completed yet" }
        end
      end

      triggers
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

    # --- Helpers ---

    def review_bot?(login, provider_key: nil)
      return ProviderSupport.provider_bot_username_for?(provider_key, login) if provider_key.present?

      ProviderSupport.provider_bot_username?(login)
    end

    def related_completed_runs(project, issue)
      project.agent_runs
        .where(
          "source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
          pr_num: issue.github_number
        )
        .completed
    end

    def last_completed_code_run(project, issue)
      related_completed_runs(project, issue)
        .where.not(goal: "review")
        .order(completed_at: :desc)
        .first
    end

    def paid_agent_review_status(project, issue, unresolved_threads)
      baseline = last_completed_code_run(project, issue)&.completed_at
      latest_review_run = related_completed_runs(project, issue)
        .where(goal: "review")
        .where.not(review_posted_at: nil)
        .order(completed_at: :desc)
        .first

      return :pending unless latest_review_run&.completed_at

      return :pending unless baseline.nil? || latest_review_run.completed_at >= baseline

      return :blocked if latest_review_run.review_url.blank? || unresolved_threads.nil?

      paid_agent_review_threads_resolved?(latest_review_run, unresolved_threads) ? :completed : :followup_required
    end

    def paid_agent_review_threads_resolved?(review_run, unresolved_threads)
      unresolved_threads.none? do |thread|
        thread[:comments].any? { |comment| comment[:review_url] == review_run.review_url }
      end
    end

    def manual_review_completed?(project, issue, reviews)
      return false if reviews.nil?

      baseline = last_completed_code_run(project, issue)&.completed_at
      trusted_reviews = reviews.select do |review|
        project.trusted_github_user?(review[:user_login]) && !bot_user?(review[:user_login])
      end

      trusted_reviews.any? do |review|
        submitted_at = review[:submitted_at]
        submitted_at.present? && (baseline.nil? || submitted_at >= baseline)
      end
    end

    def pending_ci_review_actions(project, checks)
      names = project.ci_review_action_names
      return [] if names.empty?
      return names if checks.blank?

      names.reject do |name|
        conclusion = latest_check_for_review_action(checks, name)&.dig(:conclusion)
        %w[success neutral skipped].include?(conclusion)
      end
    end

    def latest_check_for_review_action(checks, action_name)
      matches = checks.select do |check|
        check[:name].to_s.casecmp?(action_name)
      end

      matches.max_by { |check| check[:started_at] || check[:completed_at] || Time.at(0) }
    end

    def append_generic_review_bot_thread_triggers!(triggers, unresolved_threads)
      return if triggers.any? { |trigger| trigger[:type] == "review_bot_threads" }

      triggers.concat(non_copilot_review_bot_thread_triggers(unresolved_threads))
    end

    def non_copilot_review_bot_thread_triggers(unresolved_threads)
      return [] if unresolved_threads.nil?

      review_bot_threads = unresolved_threads.select do |thread|
        thread[:comments].any? do |comment|
          review_bot?(comment[:author]) && !review_bot?(comment[:author], provider_key: "copilot")
        end
      end

      return [] if review_bot_threads.empty?

      [ { type: "review_bot_threads", details: "#{review_bot_threads.size} unresolved review bot thread(s)" } ]
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
