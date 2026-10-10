# frozen_string_literal: true

class PersonalAccessTokensController < ApplicationController
  before_action :set_personal_access_token, only: [ :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @personal_access_tokens = policy_scope(PersonalAccessToken).order(created_at: :desc)
  end

  def new
    @personal_access_token = PersonalAccessToken.new
    authorize @personal_access_token
  end

  # Creates the token and renders the show-once plaintext response — the
  # only moment the secret exists server-side in clear.
  # @spec MOBILE-API-001
  def create
    @personal_access_token = PersonalAccessToken.build_for(
      user: current_user,
      name: personal_access_token_params[:name],
      expires_at: personal_access_token_params[:expires_at].presence
    )
    authorize @personal_access_token

    if @personal_access_token.save
      Rails.logger.info(
        message: "personal_access_token.created",
        personal_access_token_id: @personal_access_token.id,
        user_id: current_user.id,
        account_id: current_account.id
      )
      render :created, status: :created
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    authorize @personal_access_token
    @personal_access_token.revoke!
    redirect_to personal_access_tokens_path, notice: "Token was successfully revoked."
  end

  private

  def set_personal_access_token
    @personal_access_token = policy_scope(PersonalAccessToken).find(params[:id])
  end

  def personal_access_token_params
    params.require(:personal_access_token).permit(:name, :expires_at)
  end
end
