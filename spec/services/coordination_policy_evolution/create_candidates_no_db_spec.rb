# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::CreateCandidates, :no_db do
  describe "policy-specific extraction" do
    def build_service(policy_type, configuration = {})
      described_class.new(
        policy_snapshot: {
          id: 1,
          policy_type: policy_type,
          policy_key: "#{policy_type}_policy",
          name: policy_type.humanize,
          configuration: configuration
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

    it "preserves unchanged recovery actions when a mutation only changes the default action" do
      service = build_service("recovery", {
        "recovery" => {
          "actions" => { "timeout" => "retry_same_provider" },
          "default_action" => "pause_and_notify"
        }
      })
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: { "recovery" => { "default_action" => "skip_and_continue" } }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "failure_actions" => { "timeout" => "retry_same_provider" }
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "default_action" => "skip_and_continue"
      )
    end

    it "persists escalation candidates from persisted top-level policy fields" do
      service = build_service("escalation")
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: {
          "explicit_triggers" => %w[no_progress_stuck],
          "auto_resolve_trigger_types" => %w[owner_approved],
          "human_value_threshold" => 0.45,
          "weights" => { "unified_failure_pressure" => 0.6 },
          "interruption_cost" => { "base" => 0.2 }
        }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "explicit_triggers" => %w[no_progress_stuck],
        "auto_resolve_trigger_types" => %w[owner_approved]
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "human_value_threshold" => 0.45,
        "weights" => { "unified_failure_pressure" => 0.6 },
        "interruption_cost" => { "base" => 0.2 }
      )
    end

    it "preserves unchanged escalation triggers when a mutation only changes scoring parameters" do
      service = build_service("escalation", {
        "escalation" => {
          "human_value_threshold" => 0.65,
          "explicit_triggers" => %w[no_progress_stuck],
          "auto_resolve_trigger_types" => %w[owner_approved]
        }
      })
      mutation = instance_double(
        StrategyEvolution::Mutate::Mutation,
        configuration: { "escalation" => { "human_value_threshold" => 0.45 } }
      )

      expect(service.send(:candidate_rules, mutation)).to eq(
        "explicit_triggers" => %w[no_progress_stuck],
        "auto_resolve_trigger_types" => %w[owner_approved]
      )
      expect(service.send(:candidate_parameters, mutation)).to eq(
        "human_value_threshold" => 0.45
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

    it "fails fast for unsupported policy types" do
      expect {
        build_service("lifecycle_state")
      }.to raise_error(ArgumentError, 'unsupported coordination policy type: "lifecycle_state"')
    end
  end
end
