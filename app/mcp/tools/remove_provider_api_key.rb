# frozen_string_literal: true

module Tools
  class RemoveProviderApiKey < BaseTool
    authorize :destroy?, ->(args) { provider_api_key_for(args.fetch(:provider_api_key_id)) }, policy_class: ProviderApiKeyPolicy

    def self.tool_name = "remove_provider_api_key"
    def self.write_operation? = true

    def self.description
      "Remove a provider API key owned by the current user."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          provider_api_key_id: { type: "integer" },
          confirmed: { type: "boolean" }
        },
        required: %w[provider_api_key_id confirmed]
      }
    end

    def perform(provider_api_key_id:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to remove an API key" unless confirmed

      provider_api_key = provider_api_key_for(provider_api_key_id)
      result = { id: provider_api_key.id, name: provider_api_key.name }
      provider_api_key.destroy!
      result
    end

    private

    def provider_api_key_for(provider_api_key_id)
      policy_scope(ProviderApiKey).find(provider_api_key_id)
    end
  end
end
