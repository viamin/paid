# frozen_string_literal: true

module Integrations
  class Hub
    # TODO: Restore integration_credentials (GitLab, Jira, signing, per-provider LLM tokens)
    # to the integrations UI once RBAC is implemented. Account admin role users should be
    # able to manage account-scoped credentials via IntegrationCredential. The model,
    # controller, and views are intact — just hidden from the hub until then.

    Section = Data.define(:key, :label, :description, :records)

    class << self
      def sections_for(account, user)
        sections = []

        github_tokens = account.github_tokens.order(created_at: :desc).load
        if github_tokens.any?
          sections << Section.new(
            key: :repository,
            label: "Repository Access",
            description: "Personal access tokens for code hosts.",
            records: github_tokens
          )
        end

        linear_tokens = account.linear_tokens.order(created_at: :desc).load
        if linear_tokens.any?
          sections << Section.new(
            key: :issue_tracking,
            label: "Issue Tracking",
            description: "API keys for issue and project tracking services.",
            records: linear_tokens
          )
        end

        provider_api_keys = user.provider_api_keys.order(created_at: :desc).load
        if provider_api_keys.any?
          sections << Section.new(
            key: :llm_provider,
            label: "LLM Providers",
            description: "API keys for AI providers used by agent runs.",
            records: provider_api_keys
          )
        end

        sections
      end
    end
  end
end
