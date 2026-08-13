# frozen_string_literal: true

module Integrations
  class LlmApiKeyProvider < Provider
    class << self
      def key = :llm_api_key

      def provider_name = "LLM API Keys"

      def category = :llm_provider

      def icon_svg
        '<svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true">' \
          '<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 ' \
          "1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597" \
          ".237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z\" />" \
          "</svg>"
      end

      def model_class = ProviderApiKey

      def new_path
        Rails.application.routes.url_helpers.new_provider_api_key_path
      end

      def index_path
        Rails.application.routes.url_helpers.provider_api_keys_path
      end

      def description
        "Add API keys for AI providers to use alongside or instead of subscription access."
      end

      # ProviderApiKey is user-scoped, not account-scoped
      def configured?(account)
        return false unless account

        ProviderApiKey.joins(:user).where(users: { account_id: account.id }).exists?
      end

      def token_count(account)
        return 0 unless account

        ProviderApiKey.joins(:user).where(users: { account_id: account.id }).count
      end

      def token_count_for_user(user)
        return 0 unless user

        user.provider_api_keys.count
      end
    end
  end
end
