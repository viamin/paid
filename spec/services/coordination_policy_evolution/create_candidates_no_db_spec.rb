# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::CreateCandidates, :no_db do
  describe "policy-specific extraction" do
    def build_service(policy_type)
      described_class.new(
        policy_snapshot: {
          id: 1,
          policy_type: policy_type,
          policy_key: "#{policy_type}_policy",
          name: policy_type.humanize
        },
        account: Object.new,
        mutations: []
      )
    end

    it "persists recovery candidates from persisted top-level policy fields" do
      service = build_service("recovery")
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: {
          "failure_actions" => { "timeout" => "retry_same_provider" },
          "default_action" => "pause_and_notify"
        }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "failure_actions" => { "timeout" => "retry_same_provider" }
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "default_action" => "pause_and_notify"
      )
    end

    it "persists escalation candidates from persisted top-level policy fields" do
      service = build_service("escalation")
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: {
          "explicit_triggers" => %w[operational_failure_breaker],
          "auto_resolve_trigger_types" => %w[owner_approved],
          "human_value_threshold" => 0.45,
          "weights" => { "review_goal_retry_pressure" => 0.6 },
          "interruption_cost" => { "base" => 0.2 }
        }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "explicit_triggers" => %w[operational_failure_breaker],
        "auto_resolve_trigger_types" => %w[owner_approved]
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "human_value_threshold" => 0.45,
        "weights" => { "review_goal_retry_pressure" => 0.6 },
        "interruption_cost" => { "base" => 0.2 }
      )
    end

    it "accepts legacy flat decomposition flags and ignores nil nested policy sections" do
      service = build_service("decomposition")
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: {
          "decomposition" => nil,
          "decomposition_enabled" => false,
          "min_components_to_decompose" => 4,
          "max_tasks" => 10
        }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "enabled" => false,
        "min_components_to_decompose" => 4
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "max_tasks" => 10
      )
    end
  end
end
