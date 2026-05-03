# frozen_string_literal: true

module Integrations
  class Hub
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

        if user.has_any_role?(:admin, :owner, account)
          credentials = account.integration_credentials.active.order(created_at: :desc).load
          if credentials.any?
            sections << Section.new(
              key: :integration_credentials,
              label: "Integration Credentials",
              description: "Account-managed credentials for additional providers and integrations.",
              records: credentials
            )
          end
        end

        sections
      end
    end
  end
end
