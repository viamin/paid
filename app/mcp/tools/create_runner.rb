# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-006 ONBOARD-CHAT-013
  class CreateRunner < BaseTool
    authorize :create?, ->(_args) { current_user.runners.build }, policy_class: RunnerPolicy

    def self.tool_name = "create_runner"
    def self.write_operation? = true
    def self.description = "Create one of your runners after confirmation."

    def self.input_schema
      { type: "object", properties: {
        name: { type: "string" }, runner_key: { type: "string" }, auth_type: { type: "string", enum: Runner::AUTH_TYPES },
        provider_api_key_id: { type: "integer" }, integration_credential_id: { type: "integer" }, api_provider: { type: "string" },
        enabled_for_chat: { type: "boolean" }, enabled_for_agent_runs: { type: "boolean" }, fallback_role: { type: "string" },
        tier_model_ids: { type: "object" }, confirmed: { type: "boolean" }
      }, required: %w[name runner_key auth_type confirmed] }
    end

    def perform(name:, runner_key:, auth_type:, confirmed:, provider_api_key_id: nil, integration_credential_id: nil, api_provider: nil,
      enabled_for_chat: true, enabled_for_agent_runs: true, fallback_role: "standard", tier_model_ids: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to create a runner" unless confirmed
      raise ArgumentError, "Runner key is not available" unless RunnerSupport.addable_runner_keys.include?(runner_key)

      runner = current_user.runners.create!(runner_attributes(name:, runner_key:, auth_type:, provider_api_key_id:, integration_credential_id:, api_provider:, enabled_for_chat:, enabled_for_agent_runs:, fallback_role:, tier_model_ids:))
      runner.attributes.slice("id", "name", "runner_key", "auth_type", "enabled_for_chat", "enabled_for_agent_runs", "fallback_role")
    end

    private

    def runner_attributes(name:, runner_key:, auth_type:, provider_api_key_id:, integration_credential_id:, api_provider:, enabled_for_chat:, enabled_for_agent_runs:, fallback_role:, tier_model_ids:)
      { name:, runner_key:, auth_type:, provider_api_key: provider_key(provider_api_key_id), integration_credential: credential(integration_credential_id), enabled_for_chat:, enabled_for_agent_runs:, fallback_role:, tier_model_ids:, config: api_provider.present? ? { runner_key => { "api_provider" => api_provider } } : {} }.compact
    end

    def provider_key(id)
      return if id.blank?

      current_user.provider_api_keys.find(id)
    end

    def credential(id)
      return if id.blank?

      account.integration_credentials.active.find(id)
    end
  end
end
