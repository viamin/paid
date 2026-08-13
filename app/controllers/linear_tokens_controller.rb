# frozen_string_literal: true

class LinearTokensController < ApplicationController
  before_action :set_linear_token, only: [ :show, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @linear_tokens = policy_scope(LinearToken).order(created_at: :desc)
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

    if @linear_token.save
      redirect_to linear_token_path(@linear_token), notice: "Linear API key saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    authorize @linear_token
    @linear_token.revoke!
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
