# frozen_string_literal: true

module Coordination
  class EscalationService
    STRATEGY_TYPE = "feature_orchestration"

    DEFAULT_POLICY = OrchestrationStrategies::Defaults
      .feature_orchestration
      .fetch("escalation")
      .freeze

    Result = Data.define(
      :action,
      :reason,
      :human_value_score,
      :interruption_cost,
      :net_value,
      :threshold,
      :explicit_trigger,
      :policy_source
    ) do
      def escalate? = action == "escalate"
      def defer? = action == "defer"
      def auto_resolve? = action == "auto_resolve"
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, signals:)
      @project = project
      @issue = issue
      @signals = normalize_signals(signals)
    end

    def call
      policy = resolve_policy
      result = decide(policy)
      persist_decision(result, policy)
      result
    end

    private

    attr_reader :project, :issue, :signals

    def decide(policy)
      if (trigger = explicit_trigger(policy))
        return build_result(
          action: "escalate",
          reason: signals["escalation_reason"].presence || trigger.humanize,
          human_value_score: 1.0,
          interruption_cost: interruption_cost(policy),
          threshold: policy["human_value_threshold"],
          explicit_trigger: trigger,
          policy_source: policy["source"]
        )
      end

      if auto_resolve_trigger?(policy)
        return build_result(
          action: "auto_resolve",
          reason: "automation_already_resolved",
          human_value_score: 0.0,
          interruption_cost: interruption_cost(policy),
          threshold: policy["human_value_threshold"],
          explicit_trigger: nil,
          policy_source: policy["source"]
        )
      end

      value = predict_human_value(policy)
      cost = interruption_cost(policy)

      if value - cost >= policy["human_value_threshold"]
        build_result(
          action: "escalate",
          reason: signals["escalation_reason"].presence || "human_intervention_predicted_to_help",
          human_value_score: value,
          interruption_cost: cost,
          threshold: policy["human_value_threshold"],
          explicit_trigger: nil,
          policy_source: policy["source"]
        )
      elsif defer_signal?
        build_result(
          action: "defer",
          reason: defer_reason,
          human_value_score: value,
          interruption_cost: cost,
          threshold: policy["human_value_threshold"],
          explicit_trigger: nil,
          policy_source: policy["source"]
        )
      else
        build_result(
          action: "auto_resolve",
          reason: "automation_can_finish_without_human",
          human_value_score: value,
          interruption_cost: cost,
          threshold: policy["human_value_threshold"],
          explicit_trigger: nil,
          policy_source: policy["source"]
        )
      end
    end

    def build_result(action:, reason:, human_value_score:, interruption_cost:,
      threshold:, explicit_trigger:, policy_source:)
      Result.new(
        action: action,
        reason: reason,
        human_value_score: human_value_score.round(4),
        interruption_cost: interruption_cost.round(4),
        net_value: (human_value_score - interruption_cost).round(4),
        threshold: threshold,
        explicit_trigger: explicit_trigger,
        policy_source: policy_source
      )
    end

    def resolve_policy
      strategy = OrchestrationStrategies::Resolve.call(
        strategy_type: STRATEGY_TYPE,
        account: project.account
      )

      config = strategy&.configuration
      escalation = config.is_a?(Hash) ? config.fetch("escalation", {}) : {}
      source = escalation.is_a?(Hash) && escalation.any? ? STRATEGY_TYPE : "defaults"

      normalize_policy(DEFAULT_POLICY.merge(escalation).merge("source" => source))
    rescue StandardError => e
      Rails.logger.warn(
        message: "coordination.escalation_policy_resolution_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error_message: e.message
      )
      normalize_policy(DEFAULT_POLICY.merge("source" => "fallback"))
    end

    def normalize_policy(policy)
      {
        "human_value_threshold" => Float(policy["human_value_threshold"]).clamp(0.0, 1.0),
        "explicit_triggers" => Array(policy["explicit_triggers"]).map(&:to_s),
        "auto_resolve_trigger_types" => Array(policy["auto_resolve_trigger_types"]).map(&:to_s),
        "weights" => DEFAULT_POLICY["weights"].merge(policy["weights"] || {}).transform_values { |value| Float(value) },
        "interruption_cost" => DEFAULT_POLICY["interruption_cost"]
          .merge(policy["interruption_cost"] || {})
          .transform_values { |value| Float(value) },
        "source" => policy["source"]
      }
    rescue ArgumentError, TypeError
      DEFAULT_POLICY.merge("source" => "fallback")
    end

    def explicit_trigger(policy)
      policy["explicit_triggers"].find { |name| signals[name] == true }
    end

    def auto_resolve_trigger?(policy)
      return true if signals["escalation_dismissed"] == true

      trigger_types.any? { |type| policy["auto_resolve_trigger_types"].include?(type) }
    end

    def defer_signal?
      signals["active_run_exists"] == true || signals["followup_limit_reached"] == true
    end

    def defer_reason
      return "active_run_in_progress" if signals["active_run_exists"] == true

      "followup_limit_reached"
    end

    def predict_human_value(policy)
      weights = policy["weights"]

      value = 0.0
      value += weights["operational_failure_breaker"] if signals["operational_failure_breaker"] == true
      value += weights["review_goal_retry_pressure"] * normalized_retry_pressure
      value += weights["draft_review_pressure"] * normalized_draft_pressure
      value += weights["followup_pressure"] * normalized_followup_pressure
      value += weights["blocking_triggers"] * normalized_blocking_trigger_pressure
      value += weights["owner_reviewer_present"] if signals["owner_reviewer_login"].present?
      value += weights["escalated_phase"] if signals["phase"] == "escalated"

      value.clamp(0.0, 1.0)
    end

    def interruption_cost(policy)
      costs = policy["interruption_cost"]
      cost = costs["base"]
      cost += costs["missing_owner_reviewer"] if signals["owner_reviewer_login"].blank?
      cost -= costs["draft_phase_discount"] if signals["phase"].in?(%w[draft restarted])
      cost -= costs["escalated_phase_discount"] if signals["phase"] == "escalated"
      cost.clamp(0.0, 1.0)
    end

    def normalized_retry_pressure
      normalize_counter(signals["review_goal_retry_count"], 3)
    end

    def normalized_draft_pressure
      normalize_counter(signals["draft_review_count"], 3)
    end

    def normalized_followup_pressure
      normalize_counter(signals["pr_followup_count"], 3)
    end

    def normalized_blocking_trigger_pressure
      normalize_counter(trigger_types.size, 4)
    end

    def normalize_counter(value, ceiling)
      numeric = Integer(value || 0)
      (numeric.to_f / ceiling).clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      0.0
    end

    def trigger_types
      Array(signals.dig("scan", "triggers")).filter_map do |trigger|
        type = trigger.is_a?(Hash) ? trigger["type"] || trigger[:type] : nil
        type.to_s.presence
      end.uniq
    end

    def normalize_signals(raw_signals)
      hash = raw_signals.respond_to?(:to_h) ? raw_signals.to_h : raw_signals
      hash.deep_stringify_keys
    end

    def persist_decision(result, policy)
      OrchestrationDecision.record(
        project: project,
        issue: issue,
        action: result.action,
        decision_point: "coordination_escalation_service",
        status: orchestration_status_for(result),
        signals: signals.merge(
          "trigger_types" => trigger_types,
          "policy_source" => policy["source"]
        ),
        result: {
          "decision" => result.action,
          "reason" => result.reason,
          "human_value_score" => result.human_value_score,
          "interruption_cost" => result.interruption_cost,
          "net_value" => result.net_value,
          "threshold" => result.threshold,
          "explicit_trigger" => result.explicit_trigger
        }.compact
      )
    end

    def orchestration_status_for(result)
      case result.action
      when "escalate" then "applied"
      when "defer" then "deferred"
      else "resolved"
      end
    end
  end
end
