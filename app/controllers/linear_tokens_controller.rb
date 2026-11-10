# frozen_string_literal: true

class LinearTokensController < ApplicationController
  before_action :set_linear_token, only: [ :show, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @linear_tokens = policy_scope(LinearToken).order(created_at: :desc)
    connection = current_account.tracker_configuration
    @linear_connection = connection if connection&.tracker_type == "linear"
  end

  def show
    authorize @linear_token
  end

  def new
    @linear_token = current_account.linear_tokens.build
    authorize @linear_token
  end

  def create
    @linear_token = current_account.linear_tokens.build(linear_token_params)
    @linear_token.created_by = current_user
    authorize @linear_token

    if Integrations::ConnectLinearToken.call(token: @linear_token)
      redirect_to linear_token_path(@linear_token), notice: "Linear API key saved."
    end
  rescue ActiveRecord::RecordInvalid => error
    @linear_token.errors.add(:base, error.record.errors.full_messages.join(", ")) unless error.record == @linear_token
    render :new, status: :unprocessable_content
  rescue Integrations::ConnectLinearToken::ConfigurationConflict => error
    @linear_token.errors.add(:base, error.message)
    render :new, status: :unprocessable_content
  end

  def destroy
    authorize @linear_token
    Integrations::RevokeLinearToken.call(token: @linear_token)
    redirect_to linear_tokens_path, notice: "Linear API key was successfully deactivated."
  end

  private

  def set_linear_token
    @linear_token = policy_scope(LinearToken).find(params[:id])
  end

  def linear_token_params
    params.require(:linear_token).permit(:name, :token)
  end
end
