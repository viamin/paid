# frozen_string_literal: true

class GithubTokensController < ApplicationController
  before_action :set_github_token, only: [ :show, :destroy, :repositories, :validation_status, :retry_validation ]
  skip_after_action :verify_authorized, only: :index

  def index
    @github_tokens = policy_scope(GithubToken).order(created_at: :desc)
  end

  def show
    authorize @github_token
  end

  def new
    @github_token = current_account.github_tokens.build
    authorize @github_token
  end

  def create
    @github_token = current_account.github_tokens.build(github_token_params)
    @github_token.created_by = current_user
    authorize @github_token

    if @github_token.save
      GithubTokenValidationJob.perform_later(@github_token.id)
      redirect_to github_token_path(@github_token), notice: "Token saved. Validating with GitHub..."
    else
      render :new, status: :unprocessable_content
    end
  end

  def validation_status
    authorize @github_token, :show?
  end

  def retry_validation
    authorize @github_token, :show?
    @github_token.update!(validation_status: "pending", validation_error: nil)
    GithubTokenValidationJob.perform_later(@github_token.id)
    redirect_to github_token_path(@github_token), notice: "Retrying validation..."
  end

  def repositories
    authorize @github_token, :show?

    existing_github_ids = current_account.projects.pluck(:github_id)
    repos = @github_token.cached_repositories
    available_repos = repos.reject { |r| existing_github_ids.include?(r["id"]) }

    render json: available_repos
  end

  def destroy
    authorize @github_token
    @github_token.revoke!
    redirect_to github_tokens_path, notice: "Token was successfully deactivated."
  end

  private

  def set_github_token
    @github_token = policy_scope(GithubToken).find(params[:id])
  end

  def github_token_params
    params.require(:github_token).permit(:name, :token)
  end
end
