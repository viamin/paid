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

    # GET /api/proxy/git-credentials
    def show
      github_token = @agent_run.project.github_token

      unless github_token&.active?
        render plain: "", status: :service_unavailable
        return
      end

      github_token.touch_last_used!

      render plain: credential_response(github_token.token), content_type: "text/plain"
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
  end
end
