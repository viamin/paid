# frozen_string_literal: true

module Dashboard
  class LiveBroadcaster
    def self.call(...)
      new(...).call
    end

    def initialize(account:, agent_run:)
      @account = account
      @agent_run = agent_run
    end

    def call
      broadcast_live_stats
      broadcast_active_runs
      # Paused runs are intentionally NOT broadcast here. The paused-runs
      # partial calls policy(run).resume? per-run, which requires a request
      # context (current_user) the broadcaster does not have. The section
      # refreshes on full page load where the controller provides the
      # correct policy check.
      broadcast_activity_stream
      broadcast_alert if alert_worthy?
    end

    private

    attr_reader :account, :agent_run

    def broadcast_live_stats
      Rails.cache.delete("dashboard/live_stats/#{account.id}")
      Rails.cache.delete_matched("dashboard/queue_preview/#{account.id}/*")
      Rails.cache.delete_matched("dashboard/recent_activity/#{account.id}/*")

      Turbo::StreamsChannel.broadcast_update_to(
        stream_name,
        target: "live-stats",
        partial: "dashboard/live_stats",
        locals: { stats: Dashboard::LiveStats.call(account: account) }
      )
    end

    def broadcast_active_runs
      active_runs = account_agent_runs.active.includes(:runner, :issue, :model_selection, project: [ :created_by, :account ])
        .order("agent_runs.created_at DESC")
        .limit(20)
        .to_a
      AgentRun.preload_final_runner_records(active_runs)
      AgentRun.preload_source_pull_requests(active_runs)
      AgentRun.preload_created_issue_records(active_runs)

      Turbo::StreamsChannel.broadcast_update_to(
        stream_name,
        target: "active-runs",
        partial: "dashboard/active_runs",
        locals: { active_runs: active_runs }
      )
    end

    def broadcast_activity_stream
      return unless agent_run.finished?

      Turbo::StreamsChannel.broadcast_update_to(
        stream_name,
        target: "activity-stream",
        partial: "dashboard/activity_stream",
        locals: { activity_items: Dashboard::RecentActivity.call(account: account) }
      )
    end

    def broadcast_alert
      alert_type, message = alert_content

      Turbo::StreamsChannel.broadcast_prepend_to(
        stream_name,
        target: "dashboard-alerts",
        partial: "dashboard/alert",
        locals: {
          alert_type: alert_type,
          message: message,
          dom_id_for_alert: "alert-#{agent_run.id}-#{agent_run.status}",
          alert_bg_class: alert_bg_class(alert_type),
          alert_text_class: alert_text_class(alert_type)
        }
      )
    end

    def alert_worthy?
      AgentRun::FAILURE_STATUSES.include?(agent_run.status) || agent_run.paused?
    end

    def alert_content
      case agent_run.status
      when "paused"
        violation_type = agent_run.guardrail_violation_type.presence ||
          agent_run.guardrail_context&.[]("violation_type").presence
        violation = violation_type&.tr("_", " ") || "guardrail violation"
        [ "warning", "Agent run paused for #{agent_run.project.full_name}: #{violation}. Review and resume or terminate." ]
      when "failed"
        error_detail = agent_run.error_message.presence&.then { |msg| ": #{msg.truncate(100)}" }
        [ "error", "Agent run failed for #{agent_run.project.full_name}#{error_detail}" ]
      when "timeout"
        [ "warning", "Agent run timed out for #{agent_run.project.full_name}" ]
      when "auth_expired"
        [ "warning", "Authentication expired for #{agent_run.project.full_name}" ]
      when "rate_limited"
        [ "warning", "Rate limited on #{agent_run.project.full_name}" ]
      end
    end

    def alert_bg_class(type)
      case type
      when "error" then "bg-red-50"
      when "warning" then "bg-yellow-50"
      else "bg-blue-50"
      end
    end

    def alert_text_class(type)
      case type
      when "error" then "text-red-800"
      when "warning" then "text-yellow-800"
      else "text-blue-800"
      end
    end

    def account_agent_runs
      @account_agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def stream_name
      [ account, :live_dashboard ]
    end
  end
end
