# frozen_string_literal: true

module AccountAdministrationPage
  extend ActiveSupport::Concern

  private

  def load_account_administration_page
    @tenant_setting = current_account.tenant_setting!
    @memberships = current_account.account_memberships.includes(:user).order(role: :desc, created_at: :asc)
    @projects_count = current_account.projects.count
    @active_plan = current_account.billing_plans.active.order(created_at: :desc).first
    @current_billing_period = current_account.billing_periods.order(starts_at: :desc).first
    @recent_invoices = current_account.billing_invoices.order(created_at: :desc).limit(5)
    @recent_activity = current_account.account_activity_events.includes(:actor).recent.limit(20)
    @billing_visible = BillingPolicy.new(current_user, current_account).billing?
    @compliance_dashboard = Accounts::Compliance::Dashboard.call(
      account: current_account,
      tenant_setting: @tenant_setting,
      billing_visible: @billing_visible
    )
    @operations_dashboard = Accounts::Operations::Dashboard.call(
      account: current_account,
      tenant_setting: @tenant_setting,
      billing_visible: @billing_visible
    )
    @adoption_dashboard = Accounts::Adoption::Dashboard.call(
      account: current_account,
      tenant_setting: @tenant_setting
    )
  end

  def render_account_administration_error(message = "Something went wrong. Please try again.")
    load_account_administration_page
    flash.now[:alert] = message
    render "accounts/show", status: :unprocessable_content
  end
end
