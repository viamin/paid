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
      "provider_error" => [ /AllProvidersExhausted/i, /ProxyUnavailable/i, /\bprovider.?(error|fail)/i ],
      "container_error" => [ /ContainerNotProvisioned/i, /\bcontainer.?(error|fail)/i, /\bdocker.?(error|fail)/i ],
      "prompt_error" => [ /MissingPrompt/i, /\bprompt.?(error|fail|missing)/i ],
      "dependency_failure" => [ /dependency.?fail/i, /\bblocked.?by\b/i ],
      "configuration_error" => [ /McpProvisioningFailed/i, /\bconfig\w*.?(error|fail|invalid)/i, /MissingUser/i ]
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
      unless failed_run?
        persist_non_failure_decision
        return non_failure_result
      end

      category = classify_failure
      action = select_action(category)

      classification = persist_classification(category, action)
      persist_decision(classification, category, action)

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
      persist_failed_decision(e)
      Result.new(success: false, error: e.message)
    end

    private

    attr_reader :agent_run, :policy_overrides

    def failed_run?
      agent_run.status.in?(AgentRun::FAILURE_STATUSES)
    end

    def non_failure_result
      Result.new(success: false, error: "agent run status must be a failure status")
    end

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

    def persist_decision(classification, category, action)
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: orchestration_action_for(action),
        status: "applied",
        signals: build_decision_signals(category, action),
        result: build_decision_result(classification, action)
      )
    end

    def persist_non_failure_decision
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: "retry",
        status: "noop",
        signals: {
          agent_run_status: agent_run.status,
          expected_failure_statuses: AgentRun::FAILURE_STATUSES
        },
        result: {
          reason: "non_failure_status"
        }
      )
    end

    def persist_failed_decision(error)
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: "retry",
        status: "failed",
        signals: {
          agent_run_status: agent_run.status
        },
        result: {
          error_class: error.class.name,
          error_message: error.message
        }
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

    def orchestration_action_for(action)
      case action
      when "retry_same_provider", "retry_alternate_provider", "reconfigure_and_retry"
        "retry"
      when "pause_and_notify"
        "pause"
      when "escalate_model"
        "escalate"
      when "cancel_workflow"
        "cancel"
      when "skip_and_continue"
        "continue"
      else
        "retry"
      end
    end

    def build_decision_signals(category, action)
      {
        failure_category: category,
        failure_subcategory: extract_subcategory,
        agent_run_status: agent_run.status,
        parent_workflow_id: agent_run.parent_workflow_id,
        chosen_action: action
      }.merge(build_failure_context)
        .compact
    end

    def build_decision_result(classification, action)
      {
        failure_classification_id: classification.id,
        chosen_action: action,
        action_params: classification.action_params,
        action_status: classification.action_status
      }.compact
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
