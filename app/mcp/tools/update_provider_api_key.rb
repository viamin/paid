# frozen_string_literal: true

module Tools
  class UpdateProviderApiKey < BaseTool
    authorize :update?, ->(args) { provider_api_key_for(args.fetch(:provider_api_key_id)) }, policy_class: ProviderApiKeyPolicy

    def self.tool_name = "update_provider_api_key"
    def self.write_operation? = true

    def self.description
      "Update or rotate a provider API key owned by the current user."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          provider_api_key_id: { type: "integer" },
          attributes: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[provider_api_key_id attributes confirmed]
      }
    end

    def perform(provider_api_key_id:, attributes:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update an API key" unless confirmed
      raise ArgumentError, "attributes must be an object" unless attributes.is_a?(Hash)

      provider_api_key = provider_api_key_for(provider_api_key_id)
      attrs = attributes.symbolize_keys.slice(:name, :api_key, :api_service_type)
      attrs.delete(:api_key) if attrs[:api_key].blank?
      provider_api_key.update!(attrs)

      {
        id: provider_api_key.id,
        name: provider_api_key.name,
        api_service_type: provider_api_key.api_service_type,
        masked_api_key: provider_api_key.masked_api_key
      }
    end

    private

    def provider_api_key_for(provider_api_key_id)
      policy_scope(ProviderApiKey).find(provider_api_key_id)
    end
  end
end
