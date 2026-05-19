# frozen_string_literal: true

class AccountMembershipsController < ApplicationController
  before_action :set_membership, only: [ :update, :destroy ]

  def create
    authorize current_account, :update?

    Accounts::InviteMember.call(
      account: current_account,
      actor: current_user,
      **invitation_params.to_h.symbolize_keys
    )

    redirect_to account_path, notice: "Invitation sent."
  rescue Accounts::AdministrationError => e
    redirect_to account_path, alert: e.message
  end

  def update
    authorize current_account, :update?

    Accounts::UpdateMembership.call(
      account: current_account,
      membership: @membership,
      actor: current_user,
      role: membership_params[:role]
    )

    redirect_to account_path, notice: "Membership updated."
  rescue Accounts::AdministrationError => e
    redirect_to account_path, alert: e.message
  end

  def destroy
    authorize current_account, :update?

    Accounts::RemoveMembership.call(
      account: current_account,
      membership: @membership,
      actor: current_user
    )

    redirect_to account_path, notice: "Membership removed."
  rescue Accounts::AdministrationError => e
    redirect_to account_path, alert: e.message
  end

  private

  def set_membership
    @membership = current_account.account_memberships.includes(:user).find(params[:id])
  end

  def invitation_params
    params.require(:invitation).permit(:email, :name, :role)
  end

  def membership_params
    params.require(:account_membership).permit(:role)
  end
end
