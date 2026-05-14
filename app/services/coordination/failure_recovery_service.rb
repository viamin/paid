# frozen_string_literal: true

module Coordination
  class FailureRecoveryService
    CATEGORY_PATTERNS = {
      "rate_limit" => [ /RateLimit/i, /rate.?limit/i, /\b429\b/ ],
      "auth_failure" => [ /AuthenticationError/i, /auth.?expir/i, /unauthorized/i, /\b403\b/ ],
      "timeout" => [ /timeout/i, /timed?\s*out/i ],
      "provider_error" => [ /AllProvidersExhausted/i, /ProxyUnavailable/i, /\bprovider.?(error|fail)/i ],
      "container_error" => [ /ContainerNotProvisioned/i, /\bcontainer.?(error|fail)/i, /\bdocker.?(error|fail)/i ],
      "prompt_error" => [ /MissingPrompt/i, /\bprompt.?(error|fail|missing)/i ],
      "dependency_failure" => [ /dependency.?fail/i, /\bblocked.?by\b/i ],
      "configuration_error" => [ /McpProvisioningFailed/i, /\bconfig\w*.?(error|fail|invalid)/i, /MissingUser/i ]
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, policy_overrides: {}, run_snapshot: {})
      @agent_run = agent_run
      @policy_overrides = policy_overrides
      @run_snapshot = run_snapshot
    end

    def call
      category = classify_failure
      policy = FailureRecoveryPolicy.call(project: agent_run.project, overrides: policy_overrides)
      action = select_action(category, policy)

      Result.new(
        failure_category: category,
        failure_subcategory: extract_subcategory,
        chosen_action: action,
        failure_context: build_failure_context.merge(policy_metadata(policy)).deep_stringify_keys,
        action_params: build_action_params(category, action).merge(policy_metadata(policy)).deep_stringify_keys,
        policy: policy
      )
    end

    private

    attr_reader :agent_run, :policy_overrides, :run_snapshot

    def classify_failure
      error_text = build_error_text

      CATEGORY_PATTERNS.each do |category, patterns|
        return category if patterns.any? { |pattern| pattern.match?(error_text) }
      end

      classify_by_status || "unknown"
    end

    def build_error_text
      [
        current_error_message,
        current_status,
        current_guardrail_violation_type
      ].compact.join(" ")
    end

    def classify_by_status
      case current_status
      when "timeout" then "timeout"
      when "rate_limited" then "rate_limit"
      when "auth_expired" then "auth_failure"
      end
    end

    def select_action(category, policy)
      policy.fetch("actions", {}).fetch(category, policy.fetch("default_action", FailureRecoveryPolicy::DEFAULT_ACTION))
    end

    def extract_subcategory
      return current_guardrail_violation_type if current_guardrail_violation_type.present?

      known_types = OrchestrationStrategies::Defaults.feature_orchestration["known_failure_types"]
      error = current_error_message.to_s
      known_types&.find { |type| error.include?(type) }
    end

    def build_failure_context
      {
        error_message: current_error_message.to_s.truncate(1000),
        status: current_status,
        final_runner: current_final_runner,
        runners_attempted: current_runners_attempted,
        runner_switches: current_runner_switches,
        guardrail_violation_type: current_guardrail_violation_type
      }.compact_blank
    end

    def build_action_params(category, action)
      {}.tap do |params|
        params[:category] = category
        params[:action] = action

        case action
        when "retry_alternate_provider"
          params[:exclude_providers] = attempted_provider_identifiers
        when "escalate_model"
          params[:current_provider] = preferred_provider_identifier
        when "retry_same_provider"
          params[:provider] = preferred_provider_identifier
        end
      end
    end

    def policy_metadata(policy)
      {
        policy_source: policy["source"],
        policy_key: policy["policy_key"],
        coordination_policy_id: policy["coordination_policy_id"],
        coordination_policy_version_id: policy["coordination_policy_version_id"],
        coordination_policy_version: policy["coordination_policy_version"]
      }.compact
    end

    def attempted_provider_identifiers
      Array(current_runners_attempted).filter_map do |attempt|
        next attempt unless attempt.is_a?(Hash)

        attempt["runner"] || attempt["provider"]
      end
    end

    def preferred_provider_identifier
      attempted_provider_identifiers.last || current_final_runner || agent_run.effective_runner
    end

    def current_status
      snapshot_value(:status)
    end

    def current_error_message
      snapshot_value(:error_message)
    end

    def current_guardrail_violation_type
      snapshot_value(:guardrail_violation_type)
    end

    def current_final_runner
      snapshot_value(:final_runner, :final_provider)
    end

    def current_runners_attempted
      snapshot_value(:runners_attempted, :providers_attempted)
    end

    def current_runner_switches
      snapshot_value(:runner_switches, :provider_switches)
    end

    def snapshot_value(key, *legacy_keys)
      keys = [ key, *legacy_keys ]
      keys.each do |candidate|
        return run_snapshot[candidate] if run_snapshot.key?(candidate)

        string_key = candidate.to_s
        return run_snapshot[string_key] if run_snapshot.key?(string_key)
      end

      keys.each do |candidate|
        return agent_run.public_send(candidate) if agent_run.respond_to?(candidate)
      end
    end

    class Result
      attr_reader :failure_category, :failure_subcategory, :chosen_action,
        :failure_context, :action_params, :policy

      def initialize(failure_category:, failure_subcategory:, chosen_action:,
        failure_context:, action_params:, policy:)
        @failure_category = failure_category
        @failure_subcategory = failure_subcategory
        @chosen_action = chosen_action
        @failure_context = failure_context
        @action_params = action_params
        @policy = policy
      end
    end
  end
end
