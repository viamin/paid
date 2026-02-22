# frozen_string_literal: true

module Activities
  # Scans open pull requests with the `paid-generated` label for signals
  # that require follow-up agent work. Runs after FetchIssuesActivity in
  # the GitHubPollWorkflow poll cycle.
  #
  # Signals detected:
  #   1. CI failures (failed/cancelled/timed_out check runs)
  #   2. Unresolved review threads from trusted users
  #   3. Conversation comments from trusted users after last agent run
  #   4. Changes-requested PR reviews from trusted users
  #   5. Actionable labels matching project.pr_action_labels
  #   6. Merge conflicts (when auto_fix_merge_conflicts is enabled)
  #
  # Returns a list of PRs needing follow-up with trigger reasons.
  class ScanPaidPrsActivity < BaseActivity
    activity_name "ScanPaidPrs"

    PAID_GENERATED_LABEL = "paid-generated"
    MIN_COMMENT_LENGTH = 20

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
        .select { |issue| issue.has_label?(PAID_GENERATED_LABEL) }
    end

    def scan_pr(project, client, issue)
      return nil if active_run_exists?(project, issue)
      return nil if followup_limit_reached?(project, issue)

      triggers = detect_triggers(project, client, issue)
      return nil if triggers.empty?

      issue.increment!(:pr_followup_count)
      remove_actionable_labels(client, project, issue, triggers)
      log_triggers(project, issue, triggers)

      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        triggers: triggers
      }
    end

    def active_run_exists?(project, issue)
      project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .active
        .exists?
    end

    def followup_limit_reached?(project, issue)
      issue.pr_followup_count >= project.max_pr_followup_runs
    end

    def last_completed_run(project, issue)
      project.agent_runs
        .where(source_pull_request_number: issue.github_number)
        .completed
        .order(completed_at: :desc)
        .first
    end

    def detect_triggers(project, client, issue)
      last_run = last_completed_run(project, issue)
      triggers = []

      triggers.concat(check_ci_failures(client, project, issue))
      triggers.concat(check_review_threads(client, project, issue))
      triggers.concat(check_conversation_comments(client, project, issue, last_run))
      triggers.concat(check_changes_requested(client, project, issue, last_run))
      triggers.concat(check_actionable_labels(project, issue))
      triggers.concat(check_merge_conflicts(client, project, issue))

      triggers
    end

    def check_ci_failures(client, project, issue)
      pr = client.pull_request(project.full_name, issue.github_number)
      checks = client.check_runs_for_ref(project.full_name, pr.head.sha)

      # Skip if any checks are still pending
      return [] if checks.any? { |c| c[:conclusion].nil? }

      failed = checks.select { |c| %w[failure cancelled timed_out].include?(c[:conclusion]) }
      return [] if failed.empty?

      [ { type: "ci_failure", details: failed.map { |c| c[:name] } } ]
    rescue GithubClient::Error => e
      log_signal_error("ci_failures", project, issue, e)
      []
    end

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

      # Group reviews by user to find the latest review per user
      latest_by_user = reviews
        .select { |r| project.trusted_github_user?(r[:user_login]) && !bot_user?(r[:user_login]) }
        .group_by { |r| r[:user_login]&.downcase }
        .transform_values { |user_reviews| user_reviews.max_by { |r| r[:submitted_at].to_s } }

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

    def check_merge_conflicts(client, project, issue)
      return [] unless project.auto_fix_merge_conflicts

      pr = client.pull_request(project.full_name, issue.github_number)

      # GitHub's mergeable field can be nil while computing; treat nil as "not ready"
      return [] if pr.mergeable.nil? || pr.mergeable

      [ { type: "merge_conflicts", details: "PR has merge conflicts" } ]
    rescue GithubClient::Error => e
      log_signal_error("merge_conflicts", project, issue, e)
      []
    end

    def remove_actionable_labels(client, project, issue, triggers)
      label_trigger = triggers.find { |t| t[:type] == "actionable_labels" }
      return unless label_trigger

      label_trigger[:details].each do |label|
        client.remove_label_from_issue(project.full_name, issue.github_number, label)
      rescue GithubClient::Error => e
        logger.warn(
          message: "pr_scanner.remove_label_failed",
          project_id: project.id,
          pr_number: issue.github_number,
          label: label,
          error: e.message
        )
      end
    end

    def bot_user?(login)
      return true if login.blank?

      login.end_with?("[bot]") || login.include?("bot")
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
