# frozen_string_literal: true

module SecurityAlerts
  # Closes synthetic issues whose upstream CodeQL code scanning alerts are no
  # longer open (fixed, dismissed, or auto_dismissed upstream).
  #
  # Skips issues with active agent runs to avoid orphaned work.
  # Sets github_state to "closed" for all resolved alerts; preserves
  # paid_state "failed" for diagnostic value while marking others "completed".
  class ReconcileResolved
    def initialize(project, current_open_alerts, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
      @project = project
      @current_open_alerts = current_open_alerts
      @source = source
    end

    def call
      id_offset =
        case @source
        when Issue::SYNTHETIC_CODE_SCANNING_SOURCE
          Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
        else
          raise ArgumentError, "Unsupported synthetic issue source for SecurityAlerts::ReconcileResolved: #{@source.inspect}"
        end

      open_alert_ids = @current_open_alerts
        .select { |a| a[:state] == "open" }
        .map { |a| id_offset + a[:number] }
        .to_set

      scope = @project.issues.where(
        github_state: "open",
        source: @source
      )
      scope = scope.where.not(github_issue_id: open_alert_ids) if open_alert_ids.any?

      # Exclude issues with active agent runs — closing them mid-run would
      # leave orphaned runs attached to completed/closed issues.
      active_runs = AgentRun.where(
        issue_id: scope.select(:id),
        status: AgentRun::UNFINISHED_STATUSES
      )
      active_run_count = active_runs.count
      if active_run_count.positive?
        Rails.logger.warn(
          message: "github_sync.security_active_runs_for_resolved_alerts",
          project_id: @project.id,
          active_run_count: active_run_count
        )
      end

      scope = scope.where.not(id: active_runs.select(:issue_id))

      now = Time.current
      # Close github_state for all resolved alerts. Preserve paid_state for
      # failed issues (diagnostic value) while marking others as completed.
      closed_count = scope.update_all(
        ActiveRecord::Base.sanitize_sql_array([
          "github_state = 'closed', paid_state = CASE WHEN paid_state = 'failed' THEN paid_state ELSE 'completed' END, updated_at = ?, github_updated_at = ?",
          now, now
        ])
      )
      return if closed_count.zero?

      # update_all bypasses callbacks, so manually broadcast UI updates.
      @project.broadcast_issues_update
      Rails.logger.info(
        message: "github_sync.security_reconciled_resolved_alerts",
        project_id: @project.id,
        closed_count: closed_count
      )
    end
  end
end
