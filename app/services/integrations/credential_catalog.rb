# frozen_string_literal: true

module Integrations
  # TODO: This catalog will serve the integrations hub UI once RBAC is implemented.
  # Account admin role users will be able to add/manage account-scoped credentials
  # for GitLab, Jira, signing, and per-provider LLM tokens via this catalog.
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
      llm_provider: {
        label: "LLM Providers",
        description: "API keys and OAuth tokens stored in Paid for provider integrations and future runtime wiring."
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
      "jira" => {
        key: "jira",
        label: "Jira",
        description: "API keys or OAuth tokens for Jira issue sync and planning workflows.",
        category: :issue_tracking,
        auth_kinds: %w[api_key oauth_token]
      },
      "github_signing" => {
        key: "github_signing",
        label: "GitHub Signing",
        description: "Signing credentials for future verified commit and tag workflows.",
        category: :signing,
        auth_kinds: %w[signing_token]
      }
    }.freeze

    module_function

    def provider_services
      ProviderSupport.supported_provider_keys
        .index_with do |provider_key|
          {
            key: provider_key.to_s,
            label: ::Provider.display_name(provider_key),
            description: "Stored #{::Provider.display_name(provider_key)} " \
              "credentials for API-key or OAuth-based access. " \
              "Runtime use will be wired in a follow-up.",
            category: :llm_provider,
            auth_kinds: %w[api_key oauth_token]
          }
        end
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
