# frozen_string_literal: true

module Dashboard
  class Broadcast
    attr_reader :account, :agent_run

    def initialize(account:, agent_run:)
      @account = account
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      broadcast_live_stats
      broadcast_active_runs
      broadcast_activity_stream
      broadcast_alert if alert_worthy?
    end

    private

    def broadcast_live_stats
      stats = Dashboard::LiveStats.call(account: account)

      Turbo::StreamsChannel.broadcast_update_to(
        [ account, :dashboard ],
        target: "live-stats",
        partial: "dashboard/live_stats",
        locals: { stats: stats }
      )
    end

    def broadcast_active_runs
      active_runs = account_agent_runs.active.includes(:project, :issue)
        .order("agent_runs.created_at DESC").limit(20)

      Turbo::StreamsChannel.broadcast_update_to(
        [ account, :dashboard ],
        target: "active-runs",
        partial: "dashboard/active_runs",
        locals: { active_runs: active_runs }
      )
    end

    def broadcast_activity_stream
      return unless agent_run.finished?

      recent_runs = account_agent_runs.finished.includes(:project, :issue)
        .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC")).limit(10)

      Turbo::StreamsChannel.broadcast_update_to(
        [ account, :dashboard ],
        target: "activity-stream",
        partial: "dashboard/activity_stream",
        locals: { recent_runs: recent_runs }
      )
    end

    def broadcast_alert
      alert_type, message = alert_content

      Turbo::StreamsChannel.broadcast_prepend_to(
        [ account, :dashboard ],
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
      agent_run.previous_changes.key?("status") &&
        %w[failed timeout auth_expired rate_limited].include?(agent_run.status)
    end

    def alert_content
      case agent_run.status
      when "failed"
        [ "error", "Agent run failed for #{agent_run.project.full_name}: #{agent_run.error_message.to_s.truncate(100)}" ]
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
      AgentRun.joins(:project).where(projects: { account_id: account.id })
    end
  end
end
