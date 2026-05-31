# frozen_string_literal: true

module Tools
  class ListProviderApiKeys < BaseTool
    authorize :index?, ->(_args) { ProviderApiKey }, policy_class: ProviderApiKeyPolicy

    def self.tool_name = "list_provider_api_keys"

    def self.description
      "List API keys owned by the current user."
    end

    def perform
      policy_scope(ProviderApiKey).ordered.map do |provider_api_key|
        {
          id: provider_api_key.id,
          name: provider_api_key.name,
          api_service_type: provider_api_key.api_service_type,
          masked_api_key: provider_api_key.masked_api_key,
          created_at: provider_api_key.created_at
        }
      end
    end
  end
end
