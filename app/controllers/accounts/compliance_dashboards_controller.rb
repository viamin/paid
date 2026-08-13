# frozen_string_literal: true

module Accounts
  class ComplianceDashboardsController < ApplicationController
    before_action :set_tenant_setting
    before_action :load_compliance_dashboard, only: :show

    def show
      authorize current_account, :show?
    end

    def update
      authorize current_account, :update?

      ActiveRecord::Base.transaction do
        @tenant_setting.deployment_assurance_configuration = deployment_assurance_params
        @tenant_setting.save!

        if @tenant_setting.saved_changes.except("updated_at").any?
          Accounts::RecordActivity.call(
            account: current_account,
            actor: current_user,
            action: "compliance.assurance_updated",
            subject: @tenant_setting,
            metadata: { changed_fields: [ "deployment_assurance" ] }
          )
        end
      end

      redirect_to account_compliance_dashboard_path, notice: "Compliance and deployment assurance settings saved."
    rescue ActiveRecord::RecordInvalid
      load_compliance_dashboard
      flash.now[:alert] = "Unable to save compliance settings."
      render :show, status: :unprocessable_content
    end

    def export
      authorize current_account, :update?

      pack = Accounts::Compliance::EvidencePack.call(
        account: current_account,
        tenant_setting: @tenant_setting,
        billing_visible: BillingPolicy.new(current_user, current_account).billing?
      )

      send_data JSON.pretty_generate(pack),
        filename: "compliance-evidence-#{current_account.slug}-#{Date.current}.json",
        type: "application/json"
    end

    private

    def set_tenant_setting
      @tenant_setting = current_account.tenant_setting!
    end

    def load_compliance_dashboard
      @compliance_dashboard = Accounts::Compliance::Dashboard.call(
        account: current_account,
        tenant_setting: @tenant_setting,
        billing_visible: BillingPolicy.new(current_user, current_account).billing?
      )
    end

    def deployment_assurance_params
      params.fetch(:deployment_assurance, ActionController::Parameters.new).permit(
        :deployment_model,
        :tenant_isolation,
        :network_boundary,
        :reference_architecture,
        :operations_owner,
        monitoring: %i[
          provider
          escalation_owner
          last_reviewed_at
        ],
        customer_managed_keys: %i[
          enabled
          provider
          key_reference
          last_rotated_at
          rotation_interval_days
        ],
        secret_rotation: %i[
          documented
          owner
          last_completed_at
          interval_days
        ],
        disaster_recovery: %i[
          backup_cadence
          backup_last_verified_at
          restore_last_tested_at
          upgrade_last_validated_at
          reference_stack_last_validated_at
          rpo_hours
          rto_hours
        ],
        release_management: %i[
          upgrade_channel
          maintenance_window
          maintenance_timezone
          version_support_policy
          support_window_days
        ],
        byoc: %i[
          cloud_provider
          automation_stack
          reference_stack
        ]
      ).to_h
    end
  end
end
