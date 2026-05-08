# frozen_string_literal: true

module Coordination
  # Classifies a failed agent run into a failure category and selects a
  # recovery action from coordination policies. Persists the classification
  # and chosen action for later learning.
  #
  # @example
  #   result = Coordination::FailureRecovery.call(agent_run: failed_run)
  #   result.success?            # => true
  #   result.classification      # => FailureClassification record
  #   result.failure_category    # => "provider_error"
  #   result.chosen_action       # => "retry_alternate_provider"
  class FailureRecovery
    CATEGORY_PATTERNS = {
      "rate_limit" => [ /RateLimit/i, /rate.?limit/i, /\b429\b/ ],
      "auth_failure" => [ /AuthenticationError/i, /auth.?expir/i, /unauthorized/i, /\b403\b/ ],
      "timeout" => [ /timeout/i, /timed?\s*out/i ],
      "provider_error" => [ /AllProvidersExhausted/i, /ProxyUnavailable/i, /provider/i ],
      "container_error" => [ /ContainerNotProvisioned/i, /container/i, /docker/i ],
      "prompt_error" => [ /MissingPrompt/i, /prompt/i ],
      "dependency_failure" => [ /dependency.?fail/i, /blocked/i ],
      "configuration_error" => [ /McpProvisioningFailed/i, /config/i, /MissingUser/i ]
    }.freeze

    DEFAULT_POLICY = {
      "rate_limit" => "retry_alternate_provider",
      "auth_failure" => "pause_and_notify",
      "timeout" => "retry_same_provider",
      "provider_error" => "retry_alternate_provider",
      "container_error" => "reconfigure_and_retry",
      "prompt_error" => "pause_and_notify",
      "dependency_failure" => "cancel_workflow",
      "configuration_error" => "reconfigure_and_retry",
      "unknown" => "pause_and_notify"
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, policy_overrides: {})
      @agent_run = agent_run
      @policy_overrides = policy_overrides
    end

    def call
      category = classify_failure
      action = select_action(category)

      classification = persist_classification(category, action)

      Rails.logger.info(
        message: "coordination.failure_classified",
        agent_run_id: agent_run.id,
        failure_category: category,
        chosen_action: action,
        parent_workflow_id: agent_run.parent_workflow_id
      )

      Result.new(success: true, classification: classification,
        failure_category: category, chosen_action: action)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, error: e.message)
    end

    private

    attr_reader :agent_run, :policy_overrides

    def classify_failure
      error_text = build_error_text

      CATEGORY_PATTERNS.each do |category, patterns|
        return category if patterns.any? { |p| p.match?(error_text) }
      end

      classify_by_status || "unknown"
    end

    def build_error_text
      [
        agent_run.error_message,
        agent_run.status,
        agent_run.guardrail_violation_type
      ].compact.join(" ")
    end

    def classify_by_status
      case agent_run.status
      when "timeout" then "timeout"
      when "rate_limited" then "rate_limit"
      when "auth_expired" then "auth_failure"
      end
    end

    def select_action(category)
      policy_overrides.fetch(category) { DEFAULT_POLICY.fetch(category, "pause_and_notify") }
    end

    def persist_classification(category, action)
      FailureClassification.create!(
        project: agent_run.project,
        agent_run: agent_run,
        failure_category: category,
        failure_subcategory: extract_subcategory,
        chosen_action: action,
        failure_context: build_failure_context,
        action_params: build_action_params(category, action),
        parent_workflow_id: agent_run.parent_workflow_id
      )
    end

    def extract_subcategory
      return agent_run.guardrail_violation_type if agent_run.guardrail_violation_type.present?

      known_types = OrchestrationStrategies::Defaults.feature_orchestration["known_failure_types"]
      error = agent_run.error_message.to_s
      known_types&.find { |t| error.include?(t) }
    end

    def build_failure_context
      {
        error_message: agent_run.error_message.to_s.truncate(1000),
        status: agent_run.status,
        final_provider: agent_run.final_provider,
        providers_attempted: agent_run.providers_attempted,
        provider_switches: agent_run.provider_switches,
        guardrail_violation_type: agent_run.guardrail_violation_type
      }.compact_blank
    end

    def build_action_params(category, action)
      params = { category: category, action: action }

      case action
      when "retry_alternate_provider"
        params[:exclude_providers] = attempted_provider_identifiers
      when "escalate_model"
        params[:current_provider] = preferred_provider_identifier
      when "retry_same_provider"
        params[:provider] = preferred_provider_identifier
      end

      params
    end

    def attempted_provider_identifiers
      Array(agent_run.providers_attempted).filter_map do |attempt|
        attempt.is_a?(Hash) ? attempt["provider"] : attempt
      end
    end

    def preferred_provider_identifier
      attempted_provider_identifiers.last || agent_run.effective_provider
    end

    class Result
      attr_reader :classification, :failure_category, :chosen_action, :error

      def initialize(success:, classification: nil, failure_category: nil,
        chosen_action: nil, error: nil)
        @success = success
        @classification = classification
        @failure_category = failure_category
        @chosen_action = chosen_action
        @error = error
      end

      def success? = @success
    end
  end
end
