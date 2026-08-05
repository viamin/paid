# frozen_string_literal: true

class AccountOwnershipTransfersController < ApplicationController
  include AccountAdministrationPage

  def create
    authorize current_account, :destroy?

    membership = TenantContext.with_system_access do
      AccountMembership.find_by!(id: params[:membership_id], account_id: current_account.id)
    end

    Accounts::TransferOwnership.call(
      account: current_account,
      new_owner_membership: membership,
      actor: current_user
    )

    redirect_to account_path, notice: "Ownership transferred."
  rescue Accounts::AdministrationError => e
    redirect_to account_path, alert: e.message
  rescue ActiveRecord::RecordInvalid
    render_account_administration_error
  end
end
