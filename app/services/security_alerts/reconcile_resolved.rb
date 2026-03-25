# frozen_string_literal: true

module SecurityAlerts
  # Closes synthetic issues whose Dependabot alerts are no longer open
  # (fixed, dismissed, or auto_dismissed upstream).
  #
  # Skips issues with active agent runs to avoid orphaned work, and
  # preserves failed state for diagnostic value.
  class ReconcileResolved
    def initialize(project, current_open_alerts)
      @project = project
      @current_open_alerts = current_open_alerts
    end

    def call
      open_alert_ids = @current_open_alerts
        .select { |a| a[:state] == "open" }
        .map { |a| Issue::SYNTHETIC_ISSUE_ID_OFFSET + a[:number] }
        .to_set

      scope = @project.issues.where(
        github_state: "open",
        source: Issue::SYNTHETIC_DEPENDABOT_SOURCE
      )
      scope = scope.where.not(github_issue_id: open_alert_ids) if open_alert_ids.any?

      # Exclude issues with active agent runs — closing them mid-run would
      # leave orphaned runs attached to completed/closed issues.
      active_runs = AgentRun.where(
        issue_id: scope.select(:id),
        status: %w[queued pending running]
      )
      active_run_count = active_runs.count
      if active_run_count.positive?
        Rails.logger.warn(
          message: "github_sync.security_active_runs_for_resolved_alerts",
          project_id: @project.id,
          active_run_count: active_run_count
        )
      end

      issue_ids_with_active_runs = active_runs.distinct.pluck(:issue_id)
      scope = scope.where.not(id: issue_ids_with_active_runs) if issue_ids_with_active_runs.any?
      # Preserve failed state — it carries diagnostic value and should not be
      # silently overwritten to completed.
      scope = scope.where.not(paid_state: "failed")

      count = scope.count
      return unless count > 0

      now = Time.current
      scope.update_all(
        github_state: "closed",
        paid_state: "completed",
        updated_at: now,
        github_updated_at: now
      )
      # update_all bypasses callbacks, so manually broadcast UI updates.
      @project.broadcast_issues_update
      Rails.logger.info(
        message: "github_sync.security_reconciled_resolved_alerts",
        project_id: @project.id,
        closed_count: count
      )
    end
  end
end
