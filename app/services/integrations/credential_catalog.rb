# frozen_string_literal: true

module Integrations
  module CredentialCatalog
    CATEGORY_DETAILS = {
      repository: {
        label: "Repository Access",
        description: "Credentials for code hosts, repository sync, and signing workflows."
      },
      issue_tracking: {
        label: "Issue Tracking",
        description: "Credentials for tools that manage planning, triage, and delivery state."
      },
      developer_tooling: {
        label: "Developer Tooling",
        description: "Credentials and interoperability hooks for incumbent agent tools used alongside Paid."
      },
      collaboration: {
        label: "Collaboration",
        description: "Credentials for chat and notification systems used for coexistence and event ingestion."
      },
      ci_cd: {
        label: "CI/CD",
        description: "Credentials for CI systems that emit run outcomes and workflow events into Paid."
      },
      llm_provider: {
        label: "LLM Providers",
        description: "API keys and OAuth tokens stored in Paid for provider integrations and account-level runtime fallback."
      },
      signing: {
        label: "Signing",
        description: "Credentials used for commit signing and related trust workflows."
      }
    }.freeze

    STATIC_SERVICES = {
      "gitlab" => {
        key: "gitlab",
        label: "GitLab",
        description: "API keys or OAuth tokens for GitLab repositories, merge requests, and future issue sync.",
        category: :repository,
        auth_kinds: %w[api_key oauth_token]
      },
      "bitbucket" => {
        key: "bitbucket",
        label: "Bitbucket",
        description: "API keys or OAuth tokens for Bitbucket repositories, pull requests, and migration workflows.",
        category: :repository,
        auth_kinds: %w[api_key oauth_token]
      },
      "jira" => {
        key: "jira",
        label: "Jira",
        description: "API keys or OAuth tokens for Jira issue sync and planning workflows.",
        category: :issue_tracking,
        auth_kinds: %w[api_key oauth_token]
      },
      "linear" => {
        key: "linear",
        label: "Linear",
        description: "API keys for Linear issue tracking and project management workflows.",
        category: :issue_tracking,
        auth_kinds: %w[api_key]
      },
      "azure_devops" => {
        key: "azure_devops",
        label: "Azure DevOps",
        description: "API tokens for Azure DevOps issue tracking and boards.",
        category: :issue_tracking,
        auth_kinds: %w[api_key oauth_token]
      },
      "slack" => {
        key: "slack",
        label: "Slack",
        description: "OAuth tokens for Slack notifications, approvals, and event ingestion.",
        category: :collaboration,
        auth_kinds: %w[oauth_token api_key]
      },
      "teams" => {
        key: "teams",
        label: "Microsoft Teams",
        description: "Webhook or OAuth credentials for Teams notifications and event ingestion.",
        category: :collaboration,
        auth_kinds: %w[oauth_token signing_token]
      },
      "gitlab_ci" => {
        key: "gitlab_ci",
        label: "GitLab CI",
        description: "Tokens for ingesting pipeline events and external execution outcomes from GitLab CI.",
        category: :ci_cd,
        auth_kinds: %w[api_key oauth_token]
      },
      "bitbucket_pipelines" => {
        key: "bitbucket_pipelines",
        label: "Bitbucket Pipelines",
        description: "Tokens for ingesting pipeline events and external execution outcomes from Bitbucket Pipelines.",
        category: :ci_cd,
        auth_kinds: %w[api_key oauth_token]
      },
      "github_copilot" => {
        key: "github_copilot",
        label: "GitHub Copilot",
        description: "Interoperability credentials and metadata for GitHub Copilot coexistence workflows.",
        category: :developer_tooling,
        auth_kinds: %w[oauth_token api_key]
      },
      "cursor" => {
        key: "cursor",
        label: "Cursor",
        description: "Interoperability credentials and metadata for Cursor-assisted workflows.",
        category: :developer_tooling,
        auth_kinds: %w[oauth_token api_key]
      },
      "devin" => {
        key: "devin",
        label: "Devin",
        description: "Interoperability credentials and metadata for Devin execution ingestion and migration workflows.",
        category: :developer_tooling,
        auth_kinds: %w[oauth_token api_key]
      },
      "factory" => {
        key: "factory",
        label: "Factory",
        description: "Interoperability credentials and metadata for Factory-managed agent workflows.",
        category: :developer_tooling,
        auth_kinds: %w[oauth_token api_key]
      },
      "internal_agent_workflows" => {
        key: "internal_agent_workflows",
        label: "Internal Agent Workflows",
        description: "Signing and API credentials for ingesting outcomes from existing in-house agent systems.",
        category: :developer_tooling,
        auth_kinds: %w[api_key signing_token]
      },
      "github_signing" => {
        key: "github_signing",
        label: "GitHub Signing",
        description: "Signing credentials for future verified commit and tag workflows.",
        category: :signing,
        auth_kinds: %w[signing_token]
      }
    }.freeze

    EXTRA_LLM_PROVIDER_SERVICES = {
      "minimax" => {
        key: "minimax",
        label: "MiniMax",
        description: "Stored MiniMax API keys for account-managed credential workflows.",
        category: :llm_provider,
        auth_kinds: %w[api_key]
      }
    }.freeze

    module_function

    def provider_services
      RunnerSupport.supported_runner_keys
        .index_with do |runner_key|
          {
            key: runner_key.to_s,
            label: ::Runner.display_name(runner_key),
            description: "Stored #{::Runner.display_name(runner_key)} " \
              "credentials for API-key or OAuth-based access. " \
              "Active records can back account-level runtime execution.",
            category: :llm_provider,
            auth_kinds: %w[api_key oauth_token]
          }
        end
        .merge(EXTRA_LLM_PROVIDER_SERVICES)
        .transform_keys(&:to_s)
    end

    def services
      provider_services.merge(STATIC_SERVICES)
    end

    def lookup(service_key)
      services[service_key.to_s]
    end

    def all
      services.values
    end

    def categories
      CATEGORY_DETAILS
    end

    def services_for_category(category)
      services.values.select { |definition| definition[:category] == category.to_sym }
    end

    def service_options_for(category: nil)
      definitions = category.present? ? services_for_category(category) : all
      definitions.map { |definition| [ definition[:label], definition[:key] ] }
    end

    def auth_kind_options_for(service_key, category: nil)
      definition = lookup(service_key)
      auth_kinds = if definition
        definition[:auth_kinds]
      elsif category.to_s == "signing"
        %w[signing_token]
      else
        %w[api_key oauth_token]
      end
      auth_kinds.map { |auth_kind| [ auth_kind_label(auth_kind), auth_kind ] }
    end

    def auth_kind_label(auth_kind)
      case auth_kind.to_s
      when "api_key" then "API Key"
      when "oauth_token" then "OAuth Token"
      when "signing_token" then "Signing Token"
      else auth_kind.to_s.humanize
      end
    end
  end
end
