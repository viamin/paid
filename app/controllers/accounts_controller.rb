# frozen_string_literal: true

class AccountsController < ApplicationController
  before_action :set_account_context

  def show
    authorize current_account
  end

  def update
    authorize current_account, :update?

    ActiveRecord::Base.transaction do
      current_account.update!(account_params)

      Accounts::RecordActivity.call(
        account: current_account,
        actor: current_user,
        action: "account.updated",
        subject: current_account,
        metadata: { changed_fields: current_account.saved_changes.except("updated_at").keys }
      )
    end

    redirect_to account_path, notice: "Account settings updated."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  private

  def set_account_context
    @tenant_setting = current_account.tenant_setting!
    @memberships = current_account.account_memberships.includes(:user).order(role: :desc, created_at: :asc)
    @projects_count = current_account.projects.count
    @active_plan = current_account.billing_plans.active.order(created_at: :desc).first
    @current_billing_period = current_account.billing_periods.order(starts_at: :desc).first
    @recent_invoices = current_account.billing_invoices.order(created_at: :desc).limit(5)
    @recent_activity = current_account.account_activity_events.includes(:actor).recent.limit(20)
    @billing_visible = BillingPolicy.new(current_user, current_account).billing?
  end

  def account_params
    params.require(:account).permit(:name, :default_max_tokens_per_run)
  end
end
