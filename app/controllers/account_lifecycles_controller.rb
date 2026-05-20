# frozen_string_literal: true

class AccountLifecyclesController < ApplicationController
  include AccountAdministrationPage

  def update
    authorize current_account, :destroy?

    Accounts::TransitionLifecycle.call(
      account: current_account,
      actor: current_user,
      transition: lifecycle_params[:transition]
    )

    redirect_to account_path, notice: "Account lifecycle updated."
  rescue Accounts::AdministrationError, Account::InvalidTransitionError => e
    redirect_to account_path, alert: e.message
  rescue ActiveRecord::RecordInvalid
    render_account_administration_error
  end

  private

  def lifecycle_params
    params.permit(:transition)
  end

  def allow_suspended_account_write?
    current_account.suspended? && lifecycle_params[:transition].in?(%w[reactivate deactivate])
  end
end
