# frozen_string_literal: true

module Api
  # Serves git credentials to agent containers via the secrets proxy pattern.
  #
  # Containers use a git credential helper that calls this endpoint to
  # authenticate git operations (clone, push) without exposing GitHub
  # tokens inside the container environment.
  #
  # @see Api::ContainerAuthentication for request authentication
  # @see docker/agent/scripts/git-credential-paid for the client-side helper
  class GitCredentialsController < ActionController::API
    include Api::ContainerAuthentication
    allow_chat_session_authentication!

    # GET /api/proxy/git-credentials
    def show
      project = authenticated_project
      unless project
        render json: { error: "Project is required for git credentials" }, status: :forbidden
        return
      end

      token = project.github_credential
      unless token
        render json: { error: github_credential_unavailable_message(project) }, status: :forbidden
        return
      end

      project.github_token&.touch_last_used!

      render plain: credential_response(token), content_type: "text/plain"
    rescue Github::AppInstallation::ConfigurationError => e
      Rails.logger.error(message: "git_credentials.app_installation_token_failed", error: e.message)
      render json: { error: e.message }, status: :service_unavailable
    rescue Github::AppInstallation::Error => e
      Rails.logger.error(message: "git_credentials.app_installation_token_failed", error: e.message)
      render json: { error: e.message }, status: :bad_gateway
    end

    private

    def credential_response(token)
      <<~CREDENTIALS
        protocol=https
        host=github.com
        username=x-access-token
        password=#{token}
      CREDENTIALS
    end

    def github_credential_unavailable_message(project)
      if project.github_installation_id.present? || project.github_installation.present?
        "Project GitHub App installation is missing or inactive"
      else
        "Project GitHub token is missing or inactive"
      end
    end
  end
end
