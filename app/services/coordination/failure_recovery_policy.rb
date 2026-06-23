# frozen_string_literal: true

module Coordination
  class FailureRecoveryPolicy
    POLICY_TYPE = "recovery"
    POLICY_KEY = "failure_recovery"
    DEFAULT_ACTION = "pause_and_notify"

    DEFAULT_ACTIONS = {
      "rate_limit" => "retry_alternate_runner",
      "auth_failure" => "pause_and_notify",
      "timeout" => "retry_same_runner",
      "token_budget" => "retry_alternate_runner",
      "runner_error" => "retry_alternate_runner",
      "container_error" => "reconfigure_and_retry",
      "prompt_error" => "pause_and_notify",
      "dependency_failure" => "cancel_workflow",
      "configuration_error" => "reconfigure_and_retry",
      "unknown" => DEFAULT_ACTION
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, overrides: {})
      @project = project
      @overrides = overrides
    end

    def call
      return override_policy if overrides.present?
      return fallback_policy("defaults") unless policy
      return fallback_policy("defaults") unless current_version

      merged_actions = DEFAULT_ACTIONS.merge(extract_actions(current_version.rules))
        .merge(extract_actions(current_version.parameters))

      {
        "actions" => normalize_actions(merged_actions),
        "default_action" => normalize_action(extract_default_action(current_version.rules)) ||
          normalize_action(extract_default_action(current_version.parameters)) ||
          DEFAULT_ACTION,
        "source" => "coordination_policy",
        "policy_key" => policy.policy_key,
        "coordination_policy_id" => policy.id,
        "coordination_policy_version_id" => current_version.id,
        "coordination_policy_version" => current_version.version
      }
    rescue StandardError => e
      Rails.logger.warn(
        message: "coordination.failure_recovery_policy_resolution_failed",
        project_id: project.id,
        error_class: e.class.name,
        error_message: e.message
      )
      fallback_policy("fallback")
    end

    private

    attr_reader :project, :overrides

    def policy
      @policy ||= CoordinationPolicy
        .active
        .by_type(POLICY_TYPE)
        .where(account: project.account, policy_key: POLICY_KEY)
        .where(project_id: [ nil, project.id ])
        .includes(:current_version)
        .order(Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 ELSE 1 END"), id: :desc)
        .find { |candidate| candidate.current_version.present? }
    end

    def current_version
      policy&.current_version
    end

    def override_policy
      {
        "actions" => normalize_actions(DEFAULT_ACTIONS.merge(overrides.stringify_keys)),
        "default_action" => DEFAULT_ACTION,
        "source" => "override",
        "policy_key" => POLICY_KEY,
        "coordination_policy_id" => nil,
        "coordination_policy_version_id" => nil,
        "coordination_policy_version" => nil
      }
    end

    def fallback_policy(source)
      {
        "actions" => DEFAULT_ACTIONS,
        "default_action" => DEFAULT_ACTION,
        "source" => source,
        "policy_key" => POLICY_KEY,
        "coordination_policy_id" => nil,
        "coordination_policy_version_id" => nil,
        "coordination_policy_version" => nil
      }
    end

    def extract_actions(config)
      return {} unless config.is_a?(Hash)

      config.fetch("failure_actions", config.fetch("actions", {}))
    end

    def extract_default_action(config)
      return unless config.is_a?(Hash)

      config["default_action"]
    end

    def normalize_actions(actions)
      actions.each_with_object({}) do |(category, action), normalized|
        category = category.to_s
        action = normalize_action(action)
        next unless FailureClassification::FAILURE_CATEGORIES.include?(category)
        next unless action

        normalized[category] = action
      end
    end

    def normalize_action(action)
      action = action.to_s
      return if action.blank?
      return unless FailureClassification::ACTIONS.include?(action)

      action
    end
  end
end
