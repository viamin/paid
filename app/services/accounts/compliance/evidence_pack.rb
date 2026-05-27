# frozen_string_literal: true

module Accounts
  module Compliance
    class EvidencePack
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
          schema_version: "2026-05-24",
          generated_at: Time.current.iso8601,
          account: {
            id: account.id,
            name: account.name,
            slug: account.slug,
            plan: account.plan,
            status: account.status
          },
          control_summary: dashboard.slice(:readiness_score, :counts),
          controls: dashboard[:controls],
          reference_architectures: dashboard[:reference_architectures],
          runbooks: dashboard[:runbooks],
          configuration_snapshot: {
            account_defaults: {
              default_max_tokens_per_run: account.default_max_tokens_per_run,
              scheduler_paused: account.scheduler_paused?,
              trial_ends_at: account.trial_ends_at&.iso8601
            },
            tenant_configuration: tenant_setting.configuration,
            deployment_assurance: tenant_setting.deployment_assurance_configuration
          },
          audit_export: account.account_activity_events.recent.includes(:actor).limit(100).map do |event|
            {
              occurred_at: event.created_at.iso8601,
              actor: event.actor_label,
              action: event.action,
              description: event.description,
              metadata: event.metadata
            }
          end,
          billing_snapshot: billing_snapshot
        }
      end

      private

      attr_reader :account, :tenant_setting, :billing_visible

      def dashboard
        @dashboard ||= Dashboard.call(
          account: account,
          tenant_setting: tenant_setting,
          billing_visible: billing_visible
        )
      end

      def billing_snapshot
        return { visible: false } unless billing_visible

        current_period = account.billing_periods.order(starts_at: :desc).first
        latest_invoice = account.billing_invoices.order(created_at: :desc).first
        active_plan = account.billing_plans.active.order(created_at: :desc).first

        {
          visible: true,
          active_plan: active_plan&.slice(:name, :billing_model, :period_type),
          current_period: current_period&.slice(:starts_at, :ends_at, :total_cost_cents, :total_runs),
          latest_invoice: latest_invoice&.slice(:external_id, :status, :issued_at, :total_cents)
        }
      end
    end
  end
end
