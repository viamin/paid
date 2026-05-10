# frozen_string_literal: true

module Coordination
  class EscalationPolicy
    POLICY_TYPE = "escalation"
    POLICY_KEY = "human_intervention"

    DEFAULT_POLICY = OrchestrationStrategies::Defaults
      .feature_orchestration
      .fetch("escalation")
      .freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      return fallback_policy("defaults") unless policy
      return fallback_policy("defaults") unless current_version

      DEFAULT_POLICY
        .deep_merge(current_version.rules)
        .deep_merge(current_version.parameters)
        .merge(
          "source" => "coordination_policy",
          "policy_key" => policy.policy_key,
          "coordination_policy_id" => policy.id,
          "coordination_policy_version_id" => current_version.id,
          "coordination_policy_version" => current_version.version
        )
    rescue StandardError => e
      Rails.logger.warn(
        message: "coordination.escalation_policy_resolution_failed",
        project_id: project.id,
        error_class: e.class.name,
        error_message: e.message
      )
      fallback_policy("fallback")
    end

    private

    attr_reader :project

    def policy
      @policy ||= candidates.find { |candidate| candidate.current_version.present? }
    end

    def current_version
      policy&.current_version
    end

    def candidates
      @candidates ||= CoordinationPolicy
        .active
        .by_type(POLICY_TYPE)
        .where(account: project.account, policy_key: POLICY_KEY)
        .where(project_id: [ nil, project.id ])
        .includes(:current_version)
        .order(Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 ELSE 1 END"), id: :desc)
    end

    def fallback_policy(source)
      DEFAULT_POLICY.merge(
        "source" => source,
        "policy_key" => POLICY_KEY,
        "coordination_policy_id" => nil,
        "coordination_policy_version_id" => nil,
        "coordination_policy_version" => nil
      )
    end
  end
end
