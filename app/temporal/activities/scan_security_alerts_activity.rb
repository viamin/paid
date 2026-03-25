# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open Dependabot security alerts
  # and returns actionable alerts that don't already have associated agent runs.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  # Phase 1 covers Dependabot alerts only; code scanning and secret scanning
  # will be added in later phases.
  #
  # Returns a list of alerts that need agent runs to fix them.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    SEVERITY_ORDER = %w[critical high medium low].freeze
    # Canonical constants live in Issue to avoid coupling the model to this
    # activity class. Local aliases keep activity code concise.
    SYNTHETIC_SOURCE = Issue::SYNTHETIC_DEPENDABOT_SOURCE
    SYNTHETIC_ISSUE_ID_OFFSET = Issue::SYNTHETIC_ISSUE_ID_OFFSET
    # Offset for synthetic github_number values (integer column, max ~2.1B).
    # GitHub issue/PR numbers are sequential; even the busiest repos rarely
    # exceed a few hundred thousand, so 100M provides ample headroom.
    SYNTHETIC_NUMBER_OFFSET = 100_000_000

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      return { alerts_to_fix: [] } unless project.auto_scan_security

      client = project.github_token.client
      # Fetch all open alerts (unfiltered) so reconciliation has the full
      # picture. Severity filtering is applied locally when selecting
      # actionable alerts, preventing incorrect closure of lower-severity
      # synthetic issues when the threshold is raised.
      all_alerts = fetch_alerts(project, client)
      # Only reconcile when the fetch succeeded. A nil return means the API
      # call failed, so we can't treat an empty list as authoritative.
      reconcile_resolved_alerts(project, all_alerts) unless all_alerts.nil?
      severity_filter = severities_at_or_above(project.security_severity_threshold)
      filtered_alerts = (all_alerts || []).select { |a| severity_filter.include?(a[:severity]) }
      actionable, reopen_candidates = filter_actionable_alerts(project, filtered_alerts)

      # Apply the project-level cap across both newly created and re-opened
      # issues so the total never exceeds max_security_fix_runs per cycle.
      max_runs = project.max_security_fix_runs
      issues_created = actionable.first(max_runs).filter_map do |alert|
        create_issue_for_alert(project, alert)
      end

      # Only reopen closed issues that fit within the remaining capacity.
      # Deferring the reopen avoids orphaning issues in "new" state without
      # an agent workflow when capacity is exhausted.
      remaining_slots = max_runs - issues_created.size
      if remaining_slots.positive?
        reopen_candidates.first(remaining_slots).each do |issue, alert|
          reopen_closed_issue(issue)
          issues_created << { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
        end
      end

      logger.info(
        message: "security_scanner.scan_complete",
        project_id: project_id,
        alerts_fetched: all_alerts&.size,
        alerts_fetch_skipped: all_alerts.nil?,
        alerts_actionable: actionable.size,
        issues_created: issues_created.size
      )

      { alerts_to_fix: issues_created }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit",
        non_retryable: false
      )
    end

    private

    def fetch_alerts(project, client)
      # Return nil when no alert types are enabled so reconciliation is skipped.
      # An empty array means "we checked and found nothing" — nil means "we
      # didn't check" and stale synthetic issues should not be closed.
      return nil if project.security_alert_types.empty?

      # For now this activity only fetches Dependabot alerts. If Dependabot is
      # not in the enabled alert types, return nil so callers don't treat the
      # result as an authoritative "no alerts" snapshot (which would incorrectly
      # reconcile/close existing synthetic Dependabot issues).
      return nil unless project.security_alert_types.include?("dependabot")

      # Fetch all open alerts without severity filtering. Severity is applied
      # locally in execute so reconciliation sees the full set of open alerts,
      # preventing incorrect closure when the threshold is raised.
      client.dependabot_alerts(project.full_name)
    rescue GithubClient::NotFoundError => e
      logger.warn(
        message: "security_scanner.fetch_failed",
        project_id: project.id,
        error: e.message
      )
      nil
    rescue GithubClient::ApiError => e
      # Swallow 403 (permission denied). NotFoundError (a subclass of Error,
      # not ApiError) already handles 404 above. For 5xx or unknown status
      # codes, re-raise so Temporal can apply its retry policy.
      if e.status == 403
        logger.warn(
          message: "security_scanner.fetch_failed",
          project_id: project.id,
          error: e.message,
          status: e.status
        )
        nil
      else
        raise
      end
    end

    # Returns [new_alerts, reopen_candidates]:
    #   new_alerts         — alert hashes that need a new Issue created
    #   reopen_candidates  — [issue, alert] pairs for closed synthetic Issues
    #     whose upstream alert is open again. The caller must call
    #     reopen_closed_issue only on candidates it will actually trigger a
    #     workflow for, to avoid orphaning reopened issues without an agent run.
    def filter_actionable_alerts(project, alerts)
      open_alerts = alerts.select { |a| a[:state] == "open" }
      return [ [], [] ] if open_alerts.empty?

      # Batch-load ALL existing synthetic issues (open and closed) to detect
      # both duplicates and re-opened alerts that need their Issue re-opened.
      synthetic_ids = open_alerts.map { |a| generate_synthetic_issue_id(a) }
      existing_issues = project.issues
        .where(source: SYNTHETIC_SOURCE, github_issue_id: synthetic_ids)
        .index_by(&:github_issue_id)

      new_alerts = []
      reopen_candidates = []

      open_alerts.each do |alert|
        existing = existing_issues[generate_synthetic_issue_id(alert)]

        if existing.nil?
          new_alerts << alert
        elsif existing.github_state != "open"
          # The synthetic Issue was previously closed but the upstream alert
          # is open again. Don't reopen here — defer until after capacity
          # limits are applied so we never orphan a reopened issue without
          # an agent workflow.
          reopen_candidates << [ existing, alert ]
        end
        # else: existing issue is already open — no action needed
      end

      [ new_alerts, reopen_candidates ]
    end

    def create_issue_for_alert(project, alert)
      title = build_alert_title(alert)
      body = build_alert_body(alert)
      now = Time.current

      issue = project.issues.create!(
        github_issue_id: generate_synthetic_issue_id(alert),
        github_number: generate_synthetic_number(alert),
        title: title,
        body: body,
        github_state: "open",
        # Use a trusted login (from allowed GitHub usernames) as the creator
        # so the issue is trusted for prompt building. Raises if none configured.
        github_creator_login: trusted_login_for(project),
        github_created_at: now,
        github_updated_at: now,
        paid_state: "new",
        labels: [ "security", "dependabot" ],
        source: SYNTHETIC_SOURCE
      )

      { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordNotUnique => e
      # Race condition: another poll cycle created the issue after our
      # existence check. Look up the existing issue and re-open if needed
      # so the agent run is still triggered rather than silently skipped.
      logger.warn(
        message: "security_scanner.issue_creation_race",
        project_id: project.id,
        alert_number: alert[:number],
        error: e.message
      )

      synthetic_id = generate_synthetic_issue_id(alert)
      existing = project.issues.find_by(github_issue_id: synthetic_id, source: SYNTHETIC_SOURCE)
      return nil unless existing

      reopen_closed_issue(existing) if existing.github_state != "open"
      { issue_id: existing.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordInvalid => e
      logger.warn(
        message: "security_scanner.issue_creation_failed",
        project_id: project.id,
        alert_number: alert[:number],
        error: e.message
      )
      nil
    end

    def build_alert_title(alert)
      parts = [ "[Security]" ]
      parts << "Upgrade #{alert[:package_name]}" if alert[:package_name]
      parts << "to #{alert[:patched_version]}" if alert[:patched_version]
      parts << "(#{alert[:severity]})" if alert[:severity]
      parts << "— #{alert_identifier(alert)}"
      parts.join(" ")
    end

    def build_alert_body(alert)
      lines = []
      lines << "## Dependabot Security Alert ##{alert[:number]}"
      lines << ""
      lines << "**Severity:** #{alert[:severity]}" if alert[:severity]
      lines << "**Package:** #{alert[:package_name]} (#{alert[:package_ecosystem]})" if alert[:package_name]
      lines << "**Patched version:** #{alert[:patched_version]}" if alert[:patched_version]
      lines << "**Summary:** #{alert[:summary]}" if alert[:summary]
      lines << ""
      lines << "### Goal"
      lines << ""

      if alert[:patched_version] && alert[:package_name]
        lines << "Upgrade `#{alert[:package_name]}` to version `#{alert[:patched_version]}` or later"
        lines << "to resolve this security vulnerability. Run the test suite to verify"
        lines << "the upgrade does not introduce regressions."
      else
        lines << "Fix the security vulnerability described above."
      end

      lines << ""
      lines << "[View alert on GitHub](#{alert[:html_url]})" if alert[:html_url]
      lines.join("\n")
    end

    # Close synthetic issues whose Dependabot alerts are no longer open
    # (fixed, dismissed, or auto_dismissed upstream).
    def reconcile_resolved_alerts(project, current_open_alerts)
      open_alert_ids = current_open_alerts
        .select { |a| a[:state] == "open" }
        .map { |a| generate_synthetic_issue_id(a) }
        .to_set

      stale_scope = project.issues.where(github_state: "open", source: SYNTHETIC_SOURCE)
      stale_scope = stale_scope.where.not(github_issue_id: open_alert_ids) if open_alert_ids.any?
      count = stale_scope.count

      if count > 0
        active_runs = AgentRun.where(issue_id: stale_scope.select(:id), status: %w[queued pending running])
        active_run_count = active_runs.count
        if active_run_count.positive?
          logger.warn(
            message: "security_scanner.active_runs_for_resolved_alerts",
            project_id: project.id,
            active_run_count: active_run_count
          )
        end

        now = Time.current
        stale_scope.update_all(
          github_state: "closed",
          paid_state: "completed",
          updated_at: now,
          github_updated_at: now
        )
        # update_all bypasses callbacks, so manually broadcast UI updates.
        project.broadcast_issues_update
        logger.info(
          message: "security_scanner.reconciled_resolved_alerts",
          project_id: project.id,
          closed_count: count
        )
      end
    end

    # Re-opens a previously closed synthetic Issue when the upstream
    # Dependabot alert has been re-opened. Resets state so downstream
    # code (agent runs, UI) treats it as freshly actionable.
    def reopen_closed_issue(issue)
      issue.update!(
        github_state: "open",
        paid_state: "new",
        github_updated_at: Time.current
      )
    end

    def alert_identifier(alert)
      "dependabot-alert-#{alert[:number]}"
    end

    def generate_synthetic_issue_id(alert)
      SYNTHETIC_ISSUE_ID_OFFSET + alert[:number]
    end

    # Derive github_number deterministically from the alert number.
    # This eliminates the race condition that a MAX query + increment
    # would have under concurrent poll cycles.
    def generate_synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def severities_at_or_above(threshold)
      idx = SEVERITY_ORDER.index(threshold) || 1
      SEVERITY_ORDER[0..idx]
    end

    # Returns the first allowed username for the project, so synthetic issues
    # are trusted and their body can be used as the agent prompt.
    # Raises if no trusted username is configured — creating an untrusted
    # synthetic issue would cause prompt building to fail downstream.
    def trusted_login_for(project)
      login = project.allowed_github_usernames.find(&:present?)
      return login if login.present?

      raise Temporalio::Error::ApplicationError.new(
        "No trusted GitHub usernames configured for project #{project.id}",
        type: "ConfigurationError",
        non_retryable: true
      )
    end
  end
end
