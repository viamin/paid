# frozen_string_literal: true

class GithubTokenValidationJob < ApplicationJob
  queue_as :default

  retry_on GithubClient::RateLimitError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(github_token_id)
    github_token = GithubToken.find(github_token_id)
    validate_token(github_token)
  end

  private

  def validate_token(github_token)
    github_token.mark_validating!
    Rails.logger.info(message: "github_token_validation.started", github_token_id: github_token.id)

    result = github_token.validate_with_github!
    github_token.mark_validated!

    Rails.logger.info(
      message: "github_token_validation.completed",
      github_token_id: github_token.id,
      login: result[:login],
      repo_count: github_token.accessible_repositories.size
    )
  rescue GithubClient::AuthenticationError => e
    github_token.mark_validation_failed!("Token is invalid or has been revoked: #{e.message}")
    Rails.logger.error(message: "github_token_validation.auth_failed", github_token_id: github_token.id, error: e.message)
  rescue GithubClient::ApiError => e
    github_token.mark_validation_failed!("GitHub API error: #{e.message}")
    Rails.logger.error(message: "github_token_validation.api_error", github_token_id: github_token.id, error: e.message)
  end
end
