# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-005 ONBOARD-CHAT-012
  class ListRunners < BaseTool
    authorize :index?, ->(_args) { Runner }, policy_class: RunnerPolicy

    def self.tool_name = "list_runners"
    def self.description = "List your runners and runner keys that can be added."

    def perform
      runners = policy_scope(Runner).ordered.to_a
      states = current_user.runner_states.where(runner_name: runners.map(&:state_key)).index_by(&:runner_name)
      { runners: runners.map { |runner| serialize(runner, states[runner.state_key]) }, addable_runner_keys: RunnerSupport.addable_runner_keys }
    end

    private

    def serialize(runner, state)
      runner.attributes.slice("id", "name", "runner_key", "auth_type", "enabled_for_chat", "enabled_for_agent_runs", "fallback_role").merge(
        "service_type" => runner.provider_api_key&.api_service_type,
        "free_model_policy" => runner.free_model_policy?,
        "zero_data_retention" => runner.zero_data_retention_configuration.deep_stringify_keys,
        "health" => health(state),
        "last_checked_at" => state&.quota_status_checked_at
      )
    end

    def health(state)
      return "available" unless state
      return "rate_limited" if state.rate_limited?
      return "circuit_open" if state.circuit_open?
      return "recovering" if state.circuit_half_open?

      "available"
    end
  end
end
