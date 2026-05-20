# frozen_string_literal: true

class AccountsController < ApplicationController
  include AccountAdministrationPage

  before_action :load_account_administration_page

  def show
    authorize current_account
  end

  def update
    authorize current_account, :update?

    ActiveRecord::Base.transaction do
      current_account.update!(account_params)

      if current_account.saved_changes.except("updated_at").any?
        Accounts::RecordActivity.call(
          account: current_account,
          actor: current_user,
          action: "account.updated",
          subject: current_account,
          metadata: { changed_fields: current_account.saved_changes.except("updated_at").keys }
        )
      end
    end

    redirect_to account_path, notice: "Account settings updated."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_content
  end

  private

  def account_params
    params.require(:account).permit(:name, :default_max_tokens_per_run)
  end
end
