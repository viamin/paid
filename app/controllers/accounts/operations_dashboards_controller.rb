# frozen_string_literal: true

module Accounts
  class OperationsDashboardsController < ApplicationController
    before_action :set_tenant_setting
    before_action :load_operations_dashboard, only: :show

    def show
      authorize current_account, :show?
    end

    def update
      authorize current_account, :update?

      ActiveRecord::Base.transaction do
        @tenant_setting.enterprise_operations_configuration = operations_params
        @tenant_setting.save!

        Accounts::RecordActivity.call(
          account: current_account,
          actor: current_user,
          action: "operations.dashboard_updated",
          subject: @tenant_setting,
          metadata: { changed_fields: [ "enterprise_operations" ] }
        )
      end

      redirect_to account_operations_dashboard_path, notice: "Operations settings saved."
    rescue ActiveRecord::RecordInvalid
      load_operations_dashboard
      flash.now[:alert] = "Unable to save operations settings."
      render :show, status: :unprocessable_content
    end

    def export
      authorize current_account, :update?

      report = Accounts::Operations::HealthReport.call(
        account: current_account,
        tenant_setting: @tenant_setting,
        billing_visible: BillingPolicy.new(current_user, current_account).billing?
      )

      send_data JSON.pretty_generate(report),
        filename: "operations-report-#{current_account.slug}-#{Date.current}.json",
        type: "application/json"
    end

    private

    def set_tenant_setting
      @tenant_setting = current_account.tenant_setting!
    end

    def load_operations_dashboard
      @operations_dashboard = Accounts::Operations::Dashboard.call(
        account: current_account,
        tenant_setting: @tenant_setting,
        billing_visible: BillingPolicy.new(current_user, current_account).billing?
      )
    end

    def operations_params
      params.fetch(:enterprise_operations, ActionController::Parameters.new).permit(
        service_levels: %i[
          slo_window_days
          uptime_target_percent
          queue_health_target_percent
          queue_start_slo_minutes
          urgent_response_sla_hours
          standard_response_sla_hours
        ],
        disaster_recovery: %i[
          automated_backups_enabled
          restore_drill_interval_days
          restore_owner
          last_restore_drill_at
        ],
        upgrades: %i[
          release_channel
          maintenance_window
          compatibility_lookahead_days
          last_compatibility_check_at
          last_upgrade_at
        ],
        support: %i[
          diagnostics_contact
          safe_remediation_mode
          health_report_recipients
        ],
        capacity_management: %i[
          reserved_concurrency
          queue_warning_threshold
          queue_critical_threshold
          monthly_budget_alert_percent
        ]
      ).to_h
    end
  end
end
