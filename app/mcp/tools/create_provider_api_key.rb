# frozen_string_literal: true

module Tools
  class CreateProviderApiKey < BaseTool
    authorize :create?, ->(_args) { current_user.provider_api_keys.build }, policy_class: ProviderApiKeyPolicy

    def self.tool_name = "create_provider_api_key"
    def self.write_operation? = true

    def self.description
      "Create a provider API key for the current user."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          name: { type: "string" },
          api_key: { type: "string" },
          api_service_type: { type: "string" },
          confirmed: { type: "boolean" }
        },
        required: %w[name api_key api_service_type confirmed]
      }
    end

    def perform(name:, api_key:, api_service_type:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to create an API key" unless confirmed

      provider_api_key = current_user.provider_api_keys.create!(
        name:,
        api_key:,
        api_service_type:
      )

      {
        id: provider_api_key.id,
        name: provider_api_key.name,
        api_service_type: provider_api_key.api_service_type,
        masked_api_key: provider_api_key.masked_api_key
      }
    end
  end
end
