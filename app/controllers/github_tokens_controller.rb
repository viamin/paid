# frozen_string_literal: true

class GithubTokensController < ApplicationController
  before_action :set_github_token, only: [ :show, :destroy, :repositories ]
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
      validate_token_with_github
    else
      render :new, status: :unprocessable_content
    end
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

  def validate_token_with_github
    result = @github_token.validate_with_github!
    redirect_to github_token_path(@github_token),
                notice: "Token was successfully added and validated. Connected as #{result[:login]}."
  rescue GithubClient::AuthenticationError => e
    @github_token.destroy!
    @github_token = current_account.github_tokens.build(github_token_params)
    @github_token.errors.add(:token, "is invalid or has been revoked: #{e.message}")
    render :new, status: :unprocessable_content
  rescue GithubClient::RateLimitError
    @github_token.destroy!
    @github_token = current_account.github_tokens.build(github_token_params)
    @github_token.errors.add(:base, "GitHub API rate limit exceeded. Please try again later.")
    render :new, status: :unprocessable_content
  rescue GithubClient::ApiError => e
    @github_token.destroy!
    @github_token = current_account.github_tokens.build(github_token_params)
    @github_token.errors.add(:base, "GitHub API error: #{e.message}")
    render :new, status: :unprocessable_content
  end
end
