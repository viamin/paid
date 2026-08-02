# frozen_string_literal: true

module Tools
  class RepoWriteCredentialResolver
    # @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002
    ResolvedCredential = Struct.new(:client, :credential, :identity, keyword_init: true)

    def initialize(project:, user:, session:)
      @project = project
      @user = user || session&.created_by
    end

    # @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002
    def resolve
      resolve_user_credential || resolve_project_credential || raise(ArgumentError, "Project has no GitHub credentials configured")
    end

    private

    attr_reader :project, :user

    def resolve_user_credential
      token = user_token_for_project
      return unless token

      ResolvedCredential.new(
        client: token.client,
        credential: token.token,
        identity: "user-token:#{token.name}"
      )
    end

    def resolve_project_credential
      client = project.client
      credential = project.github_credential
      return if client.blank? || credential.blank?

      ResolvedCredential.new(
        client: client,
        credential: credential,
        identity: project_identity
      )
    end

    def user_token_for_project
      return unless user

      ordered_active_user_tokens.find { |token| token_covers_project?(token) }
    end

    def ordered_active_user_tokens
      @ordered_active_user_tokens ||= user.created_github_tokens.active.to_a.sort_by do |token|
        [ token.last_used_at || Time.at(0), token.created_at || Time.at(0), token.id || 0 ]
      end.reverse
    end

    def token_covers_project?(token)
      return true if token.id == project.github_token_id

      Array(token.accessible_repositories).any? do |repository|
        repository["full_name"] == project.full_name
      end
    end

    def project_identity
      if project.github_installation.present?
        "github-app:#{project.github_installation.github_installation_id}"
      elsif project.github_token.present?
        "project-token:#{project.github_token.name}"
      else
        "unknown"
      end
    end
  end
end
