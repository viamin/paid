# frozen_string_literal: true

class AccountMembershipsController < ApplicationController
  include AccountAdministrationPage

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
  rescue ActiveRecord::RecordInvalid
    render_account_administration_error
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
  rescue ActiveRecord::RecordInvalid
    render_account_administration_error
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
  rescue ActiveRecord::RecordInvalid
    render_account_administration_error
  end

  private

  def set_membership
    @membership = current_account.account_memberships.includes(:user).find(params[:id])
  end

  def invitation_params
    invitation = params.require(:invitation)

    {
      email: invitation[:email],
      name: invitation[:name],
      role: invitation[:role]
    }
  end

  def membership_params
    membership = params.require(:account_membership)

    { role: membership[:role] }
  end
end
