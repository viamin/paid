# frozen_string_literal: true

module Integrations
  class Hub
    ICONS = {
      github: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.009-.866-.014-1.7-2.782.605-3.369-1.344-3.369-1.344-.454-1.157-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.004.071 1.532 1.033 1.532 1.033.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.221-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.027A9.564 9.564 0 0 1 12 6.844c.85.004 1.705.115 2.504.337 1.909-1.297 2.748-1.027 2.748-1.027.546 1.378.202 2.397.1 2.65.64.7 1.028 1.595 1.028 2.688 0 3.848-2.338 4.695-4.566 4.943.359.31.678.919.678 1.852 0 1.336-.012 2.415-.012 2.744 0 .268.18.58.688.482A10.019 10.019 0 0 0 22 12.017C22 6.484 17.523 2 12 2Z" clip-rule="evenodd"/></svg>',
      linear: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 5h3v14H4V5Zm6-1h10v3H10V4Zm0 6h10v3H10v-3Zm0 6h10v3H10v-3Z" fill="currentColor"/></svg>',
      provider: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 7.5A3.5 3.5 0 0 1 7.5 4h9A3.5 3.5 0 0 1 20 7.5v2A3.5 3.5 0 0 1 16.5 13h-9A3.5 3.5 0 0 1 4 9.5v-2ZM7.5 6A1.5 1.5 0 0 0 6 7.5v2A1.5 1.5 0 0 0 7.5 11h9A1.5 1.5 0 0 0 18 9.5v-2A1.5 1.5 0 0 0 16.5 6h-9ZM4 16.5A3.5 3.5 0 0 1 7.5 13h9A3.5 3.5 0 0 1 20 16.5v0A3.5 3.5 0 0 1 16.5 20h-9A3.5 3.5 0 0 1 4 16.5v0Zm3.5-1.5A1.5 1.5 0 0 0 6 16.5v0A1.5 1.5 0 0 0 7.5 18h9a1.5 1.5 0 0 0 1.5-1.5v0a1.5 1.5 0 0 0-1.5-1.5h-9Z" fill="currentColor"/></svg>',
      gitlab: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m12 21.5 4.42-13.6H7.58L12 21.5Zm-8.5-8.78L7.58 7.9l1.63 4.82H3.5Zm11.29 0 1.63-4.82 4.08 4.82h-5.71Zm-4.58 0h3.58L12 2.5l-1.79 10.22Z" fill="currentColor"/></svg>',
      jira: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 4h8.5a3.5 3.5 0 0 0 3.5 3.5V16A4 4 0 0 1 12 20H4V4Zm6 6h10v6a4 4 0 0 1-4 4h-6v-10Zm0-6h10v4H14a4 4 0 0 1-4-4Z" fill="currentColor"/></svg>',
      signing: '<svg class="h-8 w-8" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 2 5 5v6c0 5.25 3.438 10.125 7 11 3.562-.875 7-5.75 7-11V5l-7-3Zm0 4.25 3.5 1.5V11c0 3.06-1.897 6.245-3.5 7.35C10.397 17.245 8.5 14.06 8.5 11V7.75L12 6.25Zm-.75 3.25v3.5h1.5V9.5h-1.5Zm0 5v1.5h1.5V14.5h-1.5Z" fill="currentColor"/></svg>'
    }.freeze

    class << self
      def sections_for(account)
        sections = base_sections
        credential_counts = precompute_credential_counts(account)

        sections[:repository][:cards] << provider_card(Integrations::GithubProvider, account)
        sections[:issue_tracking][:cards] << provider_card(Integrations::LinearProvider, account)
        sections[:repository][:cards] << stored_credential_card(
          key: :gitlab,
          name: "GitLab",
          description: Integrations::CredentialCatalog.lookup("gitlab")[:description],
          credential_counts: credential_counts,
          category: :repository,
          service_key: "gitlab",
          icon: :gitlab
        )
        sections[:issue_tracking][:cards] << stored_credential_card(
          key: :jira,
          name: "Jira",
          description: Integrations::CredentialCatalog.lookup("jira")[:description],
          credential_counts: credential_counts,
          category: :issue_tracking,
          service_key: "jira",
          icon: :jira
        )
        sections[:llm_provider][:cards] << stored_credential_card(
          key: :provider_credentials,
          name: "Provider Credentials",
          description: provider_credentials_description,
          credential_counts: credential_counts,
          category: :llm_provider,
          icon: :provider
        )
        sections[:signing][:cards] << stored_credential_card(
          key: :github_signing,
          name: "GitHub Signing",
          description: Integrations::CredentialCatalog.lookup("github_signing")[:description],
          credential_counts: credential_counts,
          category: :signing,
          service_key: "github_signing",
          icon: :signing
        )

        categories = Integrations::CredentialCatalog.categories
        categories.keys.map do |category|
          {
            key: category,
            label: categories.fetch(category).fetch(:label),
            description: categories.fetch(category).fetch(:description),
            cards: sections.fetch(category).fetch(:cards)
          }
        end
      end

      private

      def provider_credentials_description
        names = Integrations::CredentialCatalog.services_for_category(:llm_provider).map { |s| s[:label] }
        "Store API keys or OAuth tokens for #{names.join(", ")} and future agent providers. Runtime use is not wired yet."
      end

      def base_sections
        Integrations::CredentialCatalog.categories.keys.index_with { { cards: [] } }
      end

      def precompute_credential_counts(account)
        account.integration_credentials.active.group(:category, :service_key).count
      end

      def provider_card(provider_class, account)
        {
          key: provider_class.key,
          name: provider_class.provider_name,
          description: provider_class.description,
          count: provider_class.token_count(account),
          new_path: provider_class.new_path,
          index_path: provider_class.index_path,
          icon_svg: provider_class.icon_svg
        }
      end

      def stored_credential_card(key:, name:, description:, credential_counts:, category:, icon:, service_key: nil)
        count = if service_key.present?
          credential_counts[[ category.to_s, service_key.to_s ]] || 0
        else
          credential_counts.sum { |(cat, _), cnt| cat == category.to_s ? cnt : 0 }
        end

        index_params = { category: category.to_s }
        new_params = { category: category.to_s }
        if service_key.present?
          index_params[:service_key] = service_key
          new_params[:service_key] = service_key
        end

        {
          key: key,
          name: name,
          description: description,
          count: count,
          index_path: Rails.application.routes.url_helpers.integration_credentials_path(index_params),
          new_path: Rails.application.routes.url_helpers.new_integration_credential_path(new_params),
          icon_svg: ICONS.fetch(icon)
        }
      end
    end
  end
end
