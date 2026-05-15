# frozen_string_literal: true

module Coordination
  # Persists the learned failure recovery decision for a failed agent run.
  # Classification and policy-aware action selection live in
  # Coordination::FailureRecoveryService.
  #
  # @example
  #   result = Coordination::FailureRecovery.call(agent_run: failed_run)
  #   result.success?            # => true
  #   result.classification      # => FailureClassification record
  #   result.failure_category    # => "provider_error"
  #   result.chosen_action       # => "retry_alternate_provider"
  class FailureRecovery
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, policy_overrides: {}, run_snapshot: {})
      @agent_run = agent_run
      @policy_overrides = policy_overrides
      @run_snapshot = run_snapshot
    end

    def call
      service_result = nil

      unless failed_run?
        persist_non_failure_decision
        return non_failure_result
      end

      service_result = FailureRecoveryService.call(
        agent_run: agent_run,
        policy_overrides: policy_overrides,
        run_snapshot: run_snapshot
      )

      classification = persist_classification(service_result)
      persist_decision(classification, service_result)

      Rails.logger.info(
        message: "coordination.failure_classified",
        agent_run_id: agent_run.id,
        failure_category: service_result.failure_category,
        chosen_action: service_result.chosen_action,
        policy_source: service_result.policy["source"],
        parent_workflow_id: current_parent_workflow_id
      )

      Result.new(success: true, classification: classification,
        failure_category: service_result.failure_category,
        chosen_action: service_result.chosen_action)
    rescue ActiveRecord::RecordInvalid => e
      persist_failed_decision(
        e,
        category: service_result&.failure_category,
        subcategory: service_result&.failure_subcategory,
        action: service_result&.chosen_action || "retry",
        policy: service_result&.policy || {},
        failure_context: service_result&.failure_context || {}
      )
      Result.new(success: false, error: e.message)
    end

    private

    attr_reader :agent_run, :policy_overrides, :run_snapshot

    def failed_run?
      current_status.in?(AgentRun::FAILURE_STATUSES)
    end

    def non_failure_result
      Result.new(success: false, error: "agent run status must be a failure status")
    end

    def persist_classification(service_result)
      FailureClassification.create!(
        project: agent_run.project,
        agent_run: agent_run,
        failure_category: service_result.failure_category,
        failure_subcategory: service_result.failure_subcategory,
        chosen_action: service_result.chosen_action,
        failure_context: service_result.failure_context,
        action_params: service_result.action_params,
        parent_workflow_id: current_parent_workflow_id
      )
    end

    def persist_decision(classification, service_result)
      OrchestrationDecision.record!(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: orchestration_action_for(service_result.chosen_action),
        status: "applied",
        signals: build_decision_signals(service_result),
        result: build_decision_result(classification, service_result)
      )
    end

    def persist_non_failure_decision
      OrchestrationDecision.record!(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: "noop",
        status: "noop",
        signals: {
          agent_run_status: current_status,
          expected_failure_statuses: AgentRun::FAILURE_STATUSES
        },
        result: {
          reason: "non_failure_status"
        }
      )
    end

    def persist_failed_decision(error, category:, subcategory: nil, action: "retry", policy: {}, failure_context: {})
      OrchestrationDecision.record(
        project: agent_run.project,
        issue: agent_run.issue,
        agent_run: agent_run,
        decision_point: "coordination_failure_recovery",
        action: orchestration_action_for(action),
        status: "failed",
        signals: build_decision_signals_from_values(
          category: category,
          subcategory: subcategory,
          action: action,
          policy: policy,
          failure_context: failure_context
        ),
        result: {
          chosen_action: action,
          error_class: error.class.name,
          error_message: error.message
        }
      )
    end

    def extract_subcategory
      return current_guardrail_violation_type if current_guardrail_violation_type.present?

      known_types = OrchestrationStrategies::Defaults.feature_orchestration["known_failure_types"]
      error = current_error_message.to_s
      known_types&.find { |t| error.include?(t) }
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
      params = { category: category, action: action }

      case action
      when "retry_alternate_provider"
        params[:exclude_providers] = attempted_provider_identifiers
      when "escalate_model"
        params[:current_provider] = preferred_provider_identifier
      when "retry_same_provider"
        params[:runner] = preferred_provider_identifier
      end

      params
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

    def current_parent_workflow_id
      snapshot_value(:parent_workflow_id)
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

    def orchestration_action_for(action)
      case action
      when "noop"
        "noop"
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
        Rails.logger.warn(
          message: "coordination.unknown_orchestration_action",
          action: action,
          agent_run_id: agent_run.id
        )
        action
      end
    end

    def build_decision_signals(service_result)
      build_decision_signals_from_values(
        category: service_result.failure_category,
        subcategory: service_result.failure_subcategory,
        action: service_result.chosen_action,
        policy: service_result.policy,
        failure_context: service_result.failure_context
      )
    end

    def build_decision_signals_from_values(category:, subcategory:, action:, policy:, failure_context:)
      {
        failure_category: category,
        failure_subcategory: subcategory,
        agent_run_status: current_status,
        parent_workflow_id: current_parent_workflow_id,
        chosen_action: action,
        **decision_policy_metadata(policy, failure_context)
      }.merge(failure_context.except(*policy_metadata_keys)).compact
    end

    def build_decision_result(classification, service_result)
      {
        failure_classification_id: classification.id,
        chosen_action: service_result.chosen_action,
        action_params: classification.action_params,
        action_status: classification.action_status,
        policy_source: service_result.policy["source"]
      }.compact
    end

    def decision_policy_metadata(policy, failure_context)
      failure_context.slice(*policy_metadata_keys).symbolize_keys.presence || {
        policy_source: policy["source"],
        policy_key: policy["policy_key"],
        coordination_policy_id: policy["coordination_policy_id"],
        coordination_policy_version_id: policy["coordination_policy_version_id"],
        coordination_policy_version: policy["coordination_policy_version"]
      }.compact
    end

    def policy_metadata_keys
      %w[
        policy_source
        policy_key
        coordination_policy_id
        coordination_policy_version_id
        coordination_policy_version
      ]
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
