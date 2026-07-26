# frozen_string_literal: true

module Accounts
  module Operations
    class Dashboard
      def self.call(...)
        new(...).call
      end

      def initialize(account:, tenant_setting:, billing_visible: false, include_auto_capacity: false)
        @account = account
        @tenant_setting = tenant_setting
        @billing_visible = billing_visible
        @include_auto_capacity = include_auto_capacity
      end

      def call
        {
          configuration: configuration,
          service_levels: service_levels_payload,
          disaster_recovery: disaster_recovery_payload,
          upgrades: upgrades_payload,
          support: support_payload,
          capacity: capacity_payload
        }
      end

      private

      attr_reader :account, :tenant_setting, :billing_visible, :include_auto_capacity

      def configuration
        @configuration ||= tenant_setting.enterprise_operations_configuration
      end

      def deployment_assurance
        @deployment_assurance ||= tenant_setting.deployment_assurance_configuration
      end

      def time_window
        @time_window ||= configuration.dig("service_levels", "slo_window_days").days.ago..Time.current
      end

      def recent_runs
        @recent_runs ||= AgentRun.joins(:project)
          .where(projects: { account_id: account.id }, agent_runs: { created_at: time_window })
      end

      def recent_run_rows
        @recent_run_rows ||= recent_runs.pluck(:created_at, :started_at, :status)
      end

      def queue_monitor
        @queue_monitor ||= Scaling::QueueMonitor.cached_for_account(account)
      end

      def runner_health
        @runner_health ||= ::Dashboard::RunnerHealth.call(account: account)
      end

      def usage_period
        @usage_period ||= account.billing_periods.order(starts_at: :desc).first
      end

      def aggregated_usage
        return unless billing_visible
        return unless usage_period

        @aggregated_usage ||= Billing::AggregateTenantUsage.call(
          account: account,
          starts_at: usage_period.starts_at,
          ends_at: usage_period.ends_at
        )
      end

      def service_levels_payload
        uptime_percent = uptime_actual_percent
        queue_health_percent = queue_health_actual_percent

        {
          window_days: configuration.dig("service_levels", "slo_window_days"),
          uptime_target_percent: configuration.dig("service_levels", "uptime_target_percent"),
          uptime_actual_percent: uptime_percent,
          uptime_status: status_for_target(uptime_percent, configuration.dig("service_levels", "uptime_target_percent")),
          queue_health_target_percent: configuration.dig("service_levels", "queue_health_target_percent"),
          queue_health_actual_percent: queue_health_percent,
          queue_health_status: status_for_target(
            queue_health_percent,
            configuration.dig("service_levels", "queue_health_target_percent")
          ),
          queue_start_slo_minutes: configuration.dig("service_levels", "queue_start_slo_minutes"),
          urgent_response_sla_hours: configuration.dig("service_levels", "urgent_response_sla_hours"),
          standard_response_sla_hours: configuration.dig("service_levels", "standard_response_sla_hours"),
          monitored_runs: monitored_run_count,
          completed_runs: completed_run_count,
          open_p1_incidents: account.exception_incidents.open_incidents.by_severity("p1").count,
          open_queue_alerts: queue_monitor.alerts.count
        }
      end

      def disaster_recovery_payload
        recovery = deployment_assurance.fetch("disaster_recovery", {})
        configured = configuration.fetch("disaster_recovery", {})
        last_restore_drill_at = configured["last_restore_drill_at"].presence || recovery["restore_last_tested_at"]

        {
          automated_backups_enabled: configured["automated_backups_enabled"],
          backup_cadence: recovery["backup_cadence"],
          backup_last_verified_at: recovery["backup_last_verified_at"],
          restore_drill_interval_days: configured["restore_drill_interval_days"],
          restore_owner: configured["restore_owner"],
          last_restore_drill_at: last_restore_drill_at,
          restore_drill_status: freshness_status(last_restore_drill_at, configured["restore_drill_interval_days"]),
          recovery_point_objective_hours: recovery["rpo_hours"],
          recovery_time_objective_hours: recovery["rto_hours"]
        }
      end

      def upgrades_payload
        configured = configuration.fetch("upgrades", {})
        last_compatibility_check_at = configured["last_compatibility_check_at"].presence ||
          deployment_assurance.dig("disaster_recovery", "upgrade_last_validated_at")

        {
          release_channel: configured["release_channel"],
          maintenance_window: configured["maintenance_window"],
          compatibility_lookahead_days: configured["compatibility_lookahead_days"],
          last_compatibility_check_at: last_compatibility_check_at,
          compatibility_status: freshness_status(last_compatibility_check_at, configured["compatibility_lookahead_days"]),
          last_upgrade_at: configured["last_upgrade_at"],
          last_validated_upgrade_at: deployment_assurance.dig("disaster_recovery", "upgrade_last_validated_at")
        }
      end

      def support_payload
        configured = configuration.fetch("support", {})

        {
          diagnostics_contact: configured["diagnostics_contact"],
          safe_remediation_mode: configured["safe_remediation_mode"],
          health_report_recipients: configured["health_report_recipients"],
          runner_total: runner_health[:total],
          runner_available: runner_health[:available],
          open_incidents: account.exception_incidents.open_incidents.count,
          recent_account_events: account.account_activity_events.recent.limit(5).map(&:description),
          actions: [
            { label: "Open audit log", path: Rails.application.routes.url_helpers.account_audit_logs_path },
            { label: "Edit tenant configuration", path: Rails.application.routes.url_helpers.edit_tenant_configuration_path }
          ]
        }
      end

      def capacity_payload
        configured = configuration.fetch("capacity_management", {})
        cost_ceiling_cents = tenant_setting.effective_guardrails["max_monthly_cost_cents"]
        current_cost_cents = billing_visible ? usage_period&.total_cost_cents : nil

        {
          reserved_concurrency: configured["reserved_concurrency"],
          configured_concurrency_limit: tenant_setting.effective_guardrails["max_concurrent_runs"],
          queue_warning_threshold: configured["queue_warning_threshold"],
          queue_critical_threshold: configured["queue_critical_threshold"],
          current_queue_depth: queue_monitor.queue_depths.find { |depth| depth.type == :agent_run_queue }&.depth || 0,
          current_queue_status: queue_monitor.healthy? ? :healthy : :constrained,
          monthly_budget_alert_percent: configured["monthly_budget_alert_percent"],
          monthly_cost_ceiling_cents: cost_ceiling_cents,
          current_period_cost_cents: current_cost_cents,
          cost_ceiling_utilization_percent: utilization_percent(current_cost_cents, cost_ceiling_cents),
          project_budgets_count: account.projects.joins(:cost_budgets).distinct.count,
          total_runs_in_period: usage_period&.total_runs,
          total_compute_seconds_in_period: aggregated_usage&.dig(:compute_usage, :total_compute_seconds),
          auto_capacity: auto_capacity_payload
        }
      end

      def auto_capacity_payload
        return nil unless include_auto_capacity

        Accounts::Operations::AutoCapacityObserver.call(
          account: account,
          manual_limit: tenant_setting.effective_guardrails["max_concurrent_runs"]
        )
      end

      def monitored_run_count
        @monitored_run_count ||= recent_run_rows.count { |_, started_at, _| started_at.present? }
      end

      def completed_run_count
        @completed_run_count ||= recent_run_rows.count { |_, _, status| status == "completed" }
      end

      def uptime_actual_percent
        @uptime_actual_percent ||= begin
          total_seconds = time_window.end - time_window.begin
          if total_seconds <= 0
            100.0
          else
            downtime_seconds = p1_incidents.sum { |incident| overlap_seconds(incident) }
            percent = ((total_seconds - downtime_seconds) / total_seconds) * 100.0
            percent.round(2).clamp(0.0, 100.0)
          end
        end
      end

      def queue_health_actual_percent
        @queue_health_actual_percent ||= begin
          rows = recent_run_rows.filter_map do |created_at, started_at, _|
            next unless started_at.present?

            [ created_at, started_at ]
          end
          if rows.empty?
            100.0
          else
            target_minutes = configuration.dig("service_levels", "queue_start_slo_minutes")
            met_count = rows.count { |created_at, started_at| ((started_at - created_at) / 60.0) <= target_minutes }
            ((met_count / rows.size.to_f) * 100).round(2)
          end
        end
      end

      def p1_incidents
        @p1_incidents ||= account.exception_incidents.by_severity("p1")
          .where("last_occurred_at >= ? OR resolved_at >= ? OR status = ?", time_window.begin, time_window.begin, "open")
      end

      def overlap_seconds(incident)
        start_time = [ incident.created_at, time_window.begin ].compact.max
        end_time = [ incident.resolved_at || Time.current, time_window.end ].compact.min
        return 0 if end_time <= start_time

        end_time - start_time
      end

      def status_for_target(actual, target)
        actual >= target ? :meeting : :at_risk
      end

      def freshness_status(date_value, interval_days)
        date = parse_date(date_value)
        return :missing unless date

        date >= interval_days.days.ago.to_date ? :current : :stale
      end

      def utilization_percent(current, limit)
        return nil if current.blank? || limit.blank? || limit.zero?

        ((current.to_f / limit) * 100).round(1)
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return value.to_date if value.respond_to?(:to_date)
        return if value.blank?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
