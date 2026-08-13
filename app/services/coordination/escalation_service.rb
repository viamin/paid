# frozen_string_literal: true

module Coordination
  class EscalationService
    DEFAULT_POLICY = Coordination::EscalationPolicy::DEFAULT_POLICY

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

      signal_vector = prediction_signals
      value = predict_human_value(policy, signal_vector)
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
      normalize_policy(Coordination::EscalationPolicy.call(project: project))
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
        "source" => policy["source"],
        "policy_key" => policy["policy_key"],
        "coordination_policy_id" => policy["coordination_policy_id"],
        "coordination_policy_version_id" => policy["coordination_policy_version_id"],
        "coordination_policy_version" => policy["coordination_policy_version"]
      }
    rescue ArgumentError, TypeError
      fallback_policy
    end

    def explicit_trigger(policy)
      policy["explicit_triggers"].find { |name| signals[name] == true }
    end

    def auto_resolve_trigger?(policy)
      trigger_types.any? { |type| policy["auto_resolve_trigger_types"].include?(type) }
    end

    # Only defer for an active run. Unlike the old followup_limit_reached
    # deferral, failure_streak_limit_reached is deliberately not deferred —
    # when the unified failure limit is hit the PR should be evaluated for
    # escalation immediately so it surfaces to the owner for attention.
    def defer_signal?
      signals["active_run_exists"] == true
    end

    def defer_reason
      "active_run_in_progress" if signals["active_run_exists"] == true
    end

    def predict_human_value(policy, prediction_signals)
      weights = policy["weights"]

      value = 0.0
      value += weights["no_progress_stuck"] if prediction_signals["no_progress_stuck"]
      value += weights["operational_failure_breaker"] if prediction_signals["operational_failure_breaker"]
      value += weights["unified_failure_pressure"] * prediction_signals["unified_failure_pressure"]
      value += weights["blocking_triggers"] * prediction_signals["blocking_trigger_pressure"]
      value += weights["owner_reviewer_present"] if prediction_signals["owner_reviewer_present"]
      value += weights["escalated_phase"] if prediction_signals["escalated_phase"]

      value.clamp(0.0, 1.0)
    end

    def prediction_signals
      {
        "no_progress_stuck" => signals["no_progress_stuck"] == true,
        "operational_failure_breaker" => signals["operational_failure_breaker"] == true,
        "unified_failure_pressure" => normalized_unified_failure_pressure,
        "blocking_trigger_pressure" => normalized_blocking_trigger_pressure,
        "owner_reviewer_present" => signals["owner_reviewer_login"].present?,
        "escalated_phase" => signals["phase"] == "escalated"
      }
    end

    def interruption_cost(policy)
      costs = policy["interruption_cost"]
      cost = costs["base"]
      cost += costs["missing_owner_reviewer"] if signals["owner_reviewer_login"].blank?
      cost -= costs["draft_phase_discount"] if signals["phase"].in?(%w[draft restarted])
      cost -= costs["escalated_phase_discount"] if signals["phase"] == "escalated"
      cost.clamp(0.0, 1.0)
    end

    def normalized_unified_failure_pressure
      normalize_counter(unified_failure_count, 3)
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

    def unified_failure_count
      return 0 unless signals.key?("consecutive_unsuccessful_automatic_runs")

      signals["consecutive_unsuccessful_automatic_runs"]
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

    def fallback_policy
      {
        "human_value_threshold" => DEFAULT_POLICY["human_value_threshold"],
        "explicit_triggers" => Array(DEFAULT_POLICY["explicit_triggers"]).map(&:to_s),
        "auto_resolve_trigger_types" => Array(DEFAULT_POLICY["auto_resolve_trigger_types"]).map(&:to_s),
        "weights" => DEFAULT_POLICY["weights"].transform_values { |value| Float(value) },
        "interruption_cost" => DEFAULT_POLICY["interruption_cost"].transform_values { |value| Float(value) },
        "source" => "fallback",
        "policy_key" => Coordination::EscalationPolicy::POLICY_KEY,
        "coordination_policy_id" => nil,
        "coordination_policy_version_id" => nil,
        "coordination_policy_version" => nil
      }
    end

    def persist_decision(result, policy)
      prediction_inputs = prediction_signals

      OrchestrationDecision.record(
        project: project,
        issue: issue,
        action: result.action,
        decision_point: "coordination_escalation_service",
        status: orchestration_status_for(result),
        signals: signals.merge(
          "prediction_signals" => prediction_inputs,
          "trigger_types" => trigger_types,
          "policy_source" => policy["source"],
          "policy_key" => policy["policy_key"],
          "coordination_policy_id" => policy["coordination_policy_id"],
          "coordination_policy_version_id" => policy["coordination_policy_version_id"],
          "coordination_policy_version" => policy["coordination_policy_version"]
        ),
        result: {
          "decision" => result.action,
          "reason" => result.reason,
          "human_value_score" => result.human_value_score,
          "interruption_cost" => result.interruption_cost,
          "net_value" => result.net_value,
          "threshold" => result.threshold,
          "explicit_trigger" => result.explicit_trigger,
          "policy_source" => result.policy_source
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
