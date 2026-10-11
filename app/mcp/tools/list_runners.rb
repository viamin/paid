# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-005 ONBOARD-CHAT-012
  class ListRunners < BaseTool
    authorize :index?, ->(_args) { Runner }, policy_class: RunnerPolicy

    def self.tool_name = "list_runners"
    def self.description = "List your runners and runner keys that can be added."

    def perform
      { runners: policy_scope(Runner).ordered.map { |runner| serialize(runner) }, addable_runner_keys: RunnerSupport.addable_runner_keys }
    end

    private

    def serialize(runner)
      runner.attributes.slice("id", "name", "runner_key", "auth_type", "enabled_for_chat", "enabled_for_agent_runs", "fallback_role").merge(
        "service_type" => runner.provider_api_key&.api_service_type,
        "free_model_policy" => runner.free_model_policy?
      )
    end
  end
end
