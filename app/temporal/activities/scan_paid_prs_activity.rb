# frozen_string_literal: true

module Activities
  # Scans open pull requests with the `paid-generated` label for signals
  # that require follow-up agent work. Runs after FetchIssuesActivity in
  # the GitHubPollWorkflow poll cycle.
  #
  # Phase-aware routing:
  #   - draft: Copilot review loop (CI + Copilot threads only)
  #   - ready: Owner review phase (all trigger types)
  #   - escalated: Owner intervention needed (same as ready, no auto-merge)
  #   - merged: No scanning
  #
  # Returns a list of PRs needing follow-up with trigger reasons.
  class ScanPaidPrsActivity < BaseActivity
    activity_name "ScanPaidPrs"

    PAID_GENERATED_LABEL = "paid-generated"
    MIN_COMMENT_LENGTH = 20
    KNOWN_BOT_PREFIXES = %w[dependabot renovate github-actions].freeze

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
        .where(is_pull_request: true, github_state: "open")
        .where("labels @> ?", [ PAID_GENERATED_LABEL ].to_json)
    end

    def scan_pr(project, client, issue)
      return nil if active_run_exists?(project, issue)

      case issue.pr_review_phase
      when "draft"
        scan_draft_pr(project, client, issue)
      when "ready"
        scan_ready_pr(project, client, issue)
      when "escalated"
        scan_escalated_pr(project, client, issue)
      end
    end

    # --- Draft phase scanning ---

    def scan_draft_pr(project, client, issue)
      if issue.draft_review_count >= project.max_draft_review_rounds
        return escalate_trigger(issue)
      end

      pr_data = fetch_pr_data(client, project, issue)
      copilot_triggers = check_copilot_review_threads(client, project, issue)
      ci_triggers = check_ci_failures(client, project, issue, pr_data)

      if copilot_triggers.empty? && ci_triggers.empty?
        return ready_for_owner_trigger(issue) if ci_all_green?(client, project, pr_data)
        return nil # CI still pending
      end

      triggers = copilot_triggers + ci_triggers
      log_triggers(project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers,
        phase: "draft",
        labels_to_remove: [],
        current_draft_review_count: issue.draft_review_count
      }
    end

    # --- Ready phase scanning ---

    def scan_ready_pr(project, client, issue)
      return nil if followup_limit_reached?(project, issue)

      if owner_approved?(client, project, issue)
        return owner_approved_trigger(issue)
      end

      triggers = detect_ready_triggers(project, client, issue)
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

    def scan_escalated_pr(project, client, issue)
      return nil if followup_limit_reached?(project, issue)

      triggers = detect_ready_triggers(project, client, issue)
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
        triggers: [ { type: "ready_for_owner", details: "CI green, Copilot clean" } ],
        phase: "draft"
      }
    end

    def escalate_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "escalate_to_owner" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "escalate_to_owner", details: "Draft review limit reached" } ],
        phase: "draft"
      }
    end

    def owner_approved_trigger(issue)
      log_triggers(issue.project, issue, [ { type: "owner_approved" } ])

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: [ { type: "owner_approved", details: "Owner approved PR" } ],
        phase: "ready"
      }
    end

    # --- Shared detection logic ---

    def detect_ready_triggers(project, client, issue)
      last_run = last_completed_run(project, issue)
      pr_data = fetch_pr_data(client, project, issue)
      triggers = []

      triggers.concat(check_ci_failures(client, project, issue, pr_data))
      triggers.concat(check_review_threads(client, project, issue))
      triggers.concat(check_conversation_comments(client, project, issue, last_run))
      triggers.concat(check_changes_requested(client, project, issue, last_run))
      triggers.concat(check_actionable_labels(project, issue))
      triggers.concat(check_merge_conflicts(project, pr_data))

      triggers
    end

    def active_run_exists?(project, issue)
      project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .where(status: %w[queued pending running])
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

    def check_ci_failures(client, project, issue, pr_data)
      return [] unless pr_data

      checks = client.check_runs_for_ref(project.full_name, pr_data.head.sha)
      completed = checks.select { |c| c[:conclusion].present? }
      return [] if completed.empty?

      failed = completed.select { |c| %w[failure cancelled timed_out].include?(c[:conclusion]) }
      return [] if failed.empty?

      [ { type: "ci_failure", details: failed.map { |c| c[:name] } } ]
    rescue GithubClient::Error => e
      log_signal_error("ci_failures", project, issue, e)
      []
    end

    def ci_all_green?(client, project, pr_data)
      return false unless pr_data

      checks = client.check_runs_for_ref(project.full_name, pr_data.head.sha)
      return false if checks.empty?

      checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_scanner.ci_check_failed",
        project_id: project.id,
        error: e.message
      )
      false
    end

    # --- Review checks ---

    def check_review_threads(client, project, issue)
      threads = client.review_threads(project.full_name, issue.github_number)
      unresolved = threads.reject { |t| t[:is_resolved] }

      trusted_threads = unresolved.select do |thread|
        thread[:comments].any? do |c|
          project.trusted_github_user?(c[:author]) && !bot_user?(c[:author])
        end
      end

      return [] if trusted_threads.empty?

      [ { type: "review_threads", details: "#{trusted_threads.size} unresolved thread(s)" } ]
    rescue GithubClient::Error => e
      log_signal_error("review_threads", project, issue, e)
      []
    end

    def check_copilot_review_threads(client, project, issue)
      threads = client.review_threads(project.full_name, issue.github_number)
      unresolved = threads.reject { |t| t[:is_resolved] }

      copilot_threads = unresolved.select do |thread|
        thread[:comments].any? { |c| copilot_user?(c[:author]) }
      end

      return [] if copilot_threads.empty?

      [ { type: "copilot_review_threads", details: "#{copilot_threads.size} unresolved Copilot thread(s)" } ]
    rescue GithubClient::Error => e
      log_signal_error("copilot_review_threads", project, issue, e)
      []
    end

    def check_conversation_comments(client, project, issue, last_run)
      comments = client.issue_comments(project.full_name, issue.github_number)
      cutoff = last_run&.completed_at

      relevant = comments.select do |c|
        login = c.user&.login
        next false if bot_user?(login)
        next false unless project.trusted_github_user?(login)
        next false if cutoff && c.created_at <= cutoff
        next false if c.body.to_s.strip.length < MIN_COMMENT_LENGTH

        true
      end

      return [] if relevant.empty?

      [ { type: "conversation_comments", details: "#{relevant.size} new comment(s)" } ]
    rescue GithubClient::Error => e
      log_signal_error("conversation_comments", project, issue, e)
      []
    end

    def check_changes_requested(client, project, issue, last_run)
      reviews = client.pull_request_reviews(project.full_name, issue.github_number)
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
    rescue GithubClient::Error => e
      log_signal_error("changes_requested", project, issue, e)
      []
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

    def owner_approved?(client, project, issue)
      owner_login = project.owner_reviewer_login
      return false if owner_login.blank?

      reviews = client.pull_request_reviews(project.full_name, issue.github_number)
      owner_reviews = reviews.select { |r| r[:user_login]&.downcase == owner_login.downcase }
      return false if owner_reviews.empty?

      latest = owner_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
      latest[:state] == "APPROVED"
    rescue GithubClient::Error => e
      log_signal_error("owner_approved", project, issue, e)
      false
    end

    # --- Helpers ---

    def copilot_user?(login)
      return false if login.blank?

      normalized = login.downcase
      normalized == "copilot" || normalized == "copilot[bot]"
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
