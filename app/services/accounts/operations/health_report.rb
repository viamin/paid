# frozen_string_literal: true

module Accounts
  module Operations
    class HealthReport
      def self.call(...)
        new(...).call
      end

      def initialize(account:, tenant_setting:, billing_visible: false)
        @account = account
        @tenant_setting = tenant_setting
        @billing_visible = billing_visible
      end

      def call
        {
          schema_version: "2026-05-29",
          generated_at: Time.current.iso8601,
          account: {
            id: account.id,
            name: account.name,
            slug: account.slug,
            plan: account.plan,
            status: account.status
          },
          operations_dashboard: dashboard,
          queue_depths: Scaling::QueueMonitor.cached_for_account(account).queue_depths.map { |depth|
            {
              name: depth.name,
              type: depth.type,
              depth: depth.depth,
              status: depth.status,
              threshold_warning: depth.threshold_warning,
              threshold_critical: depth.threshold_critical
            }
          },
          runner_health: ::Dashboard::RunnerHealth.call(account: account).then { |stats|
            stats.merge(runners: stats[:runners].map { |runner|
              {
                runner: runner.runner,
                owner_email: runner.owner_email,
                auth_type: runner.auth_type,
                status: runner.status,
                available: runner.available
              }
            })
          },
          open_incidents: account.exception_incidents.open_incidents.recent.limit(20).map { |incident|
            {
              fingerprint: incident.fingerprint,
              subsystem: incident.subsystem,
              severity: incident.severity,
              status: incident.status,
              action_taken: incident.action_taken,
              last_occurred_at: incident.last_occurred_at.iso8601
            }
          },
          recent_activity: account.account_activity_events.includes(:actor).recent.limit(20).map { |event|
            {
              occurred_at: event.created_at.iso8601,
              actor: event.actor_label,
              action: event.action,
              description: event.description
            }
          },
          billing_visible: billing_visible
        }
      end

      private

      attr_reader :account, :tenant_setting, :billing_visible

      def dashboard
        @dashboard ||= Dashboard.call(
          account: account,
          tenant_setting: tenant_setting,
          billing_visible: billing_visible,
          # Health report exports are used for operator diagnostics, so they
          # include the same live tenant-specific preview shown in the UI
          # instead of a cached host-level snapshot.
          include_auto_capacity: true
        )
      end
    end
  end
end
