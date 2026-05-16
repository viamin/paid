# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::CreateCandidates do
  describe ".call" do
    let(:account) { create(:account) }
    let(:policy) do
      create(:coordination_policy, :active,
        account: account,
        policy_type: "decomposition",
        policy_key: "feature_decomposition",
        name: "Feature Decomposition").tap do |record|
          record.current_version.update!(
            version: 3,
            rules: { "enabled" => true, "min_components_to_decompose" => 2 },
            parameters: { "max_tasks" => 20, "layer_order" => %w[view model service controller] }
          )
        end
    end
    let(:mutation) do
      StrategyEvolution::Mutate::Mutation.new(
        configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup.tap do |config|
          config["decomposition"] = {
            "enabled" => true,
            "min_components_to_decompose" => 2,
            "max_tasks" => 12,
            "layer_order" => %w[view controller service model]
          }
        end,
        strategy: "risk_reduction",
        reasoning: "Reduce large decompositions",
        expected_improvement: "More reviewable plans",
        diff: [ { "path" => "/decomposition/max_tasks", "from" => nil, "to" => 12 } ],
        provenance: { "sampled_decision_ids" => [ 101, 202 ] }
      )
    end
    let(:policy_snapshot) do
      {
        id: policy.id,
        policy_type: policy.policy_type,
        policy_key: policy.policy_key,
        name: policy.name,
        version_id: policy.current_version.id,
        version: policy.current_version.version,
        llm_prompt: policy.current_version.llm_prompt,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup
      }
    end

    it "persists draft policy versions with explicit pending approval metadata" do
      candidates = described_class.call(policy_snapshot: policy_snapshot, account: account, mutations: [ mutation ])

      expect(candidates.size).to eq(1)
      expect(candidates.first.status).to eq("draft")
      expect(candidates.first.version).to eq(4)
      expect(candidates.first.metadata.dig("evolution", "approval")).to eq(
        "required" => true,
        "status" => "pending_review",
        "auto_promote" => false
      )
      expect(candidates.first.metadata.dig("evolution", "provenance", "sampled_decision_ids")).to eq([ 101, 202 ])
      expect(candidates.first.rules).to include("enabled" => true, "min_components_to_decompose" => 2)
      expect(candidates.first.parameters).to include("max_tasks" => 12)
      expect(policy.reload.current_version).not_to eq(candidates.first)
    end

    it "creates non-activatable candidates until review approval is recorded" do
      candidate = described_class.call(policy_snapshot: policy_snapshot, account: account, mutations: [ mutation ]).first

      expect(candidate).not_to be_activatable
      expect {
        policy.activate_version!(candidate)
      }.to raise_error(CoordinationPolicyVersion::InvalidTransitionError, "cannot activate version pending review approval")

      candidate.update!(metadata: candidate.metadata.deep_merge(
        "evolution" => {
          "approval" => {
            "required" => true,
            "status" => "approved",
            "auto_promote" => false
          }
        }
      ))

      expect(candidate.reload).to be_activatable
    end

    context "with recovery mutations" do
      let(:recovery_policy) do
        create(:coordination_policy, :active,
          account: account,
          policy_type: "recovery",
          policy_key: Coordination::FailureRecoveryPolicy::POLICY_KEY,
          name: "Failure Recovery")
      end
      let(:recovery_mutation) do
        StrategyEvolution::Mutate::Mutation.new(
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup.merge(
            "recovery" => {
              "actions" => {
                "timeout" => "retry_same_provider",
                "provider_error" => "retry_alternate_provider"
              },
              "default_action" => "pause_and_notify"
            }
          ),
          strategy: "recovery_refinement",
          reasoning: "Tighten learned timeout handling",
          expected_improvement: "Higher successful retries",
          diff: [ { "path" => "/recovery/actions/timeout", "from" => nil, "to" => "retry_same_provider" } ],
          provenance: {}
        )
      end
      let(:recovery_candidate) do
        described_class.call(
          policy_snapshot: {
            id: recovery_policy.id,
            policy_type: "recovery",
            policy_key: recovery_policy.policy_key,
            name: recovery_policy.name,
            version_id: recovery_policy.current_version.id,
            version: recovery_policy.current_version.version,
            configuration: recovery_mutation.configuration
          },
          account: account,
          mutations: [ recovery_mutation ]
        ).first
      end

      it "persists recovery candidates using recovery-specific rule and parameter keys" do
        expect(recovery_candidate.rules).to include(
          "failure_actions" => include("timeout" => "retry_same_provider")
        )
        expect(recovery_candidate.parameters).to include("default_action" => "pause_and_notify")
      end
    end

    context "with escalation mutations" do
      let(:escalation_policy) do
        create(:coordination_policy, :active,
          account: account,
          policy_type: "escalation",
          policy_key: Coordination::EscalationPolicy::POLICY_KEY,
          name: "Human Intervention")
      end
      let(:escalation_mutation) do
        StrategyEvolution::Mutate::Mutation.new(
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup.tap do |config|
            config["escalation"] = config.fetch("escalation", {}).merge(
              "human_value_threshold" => 0.45,
              "explicit_triggers" => %w[operational_failure_breaker],
              "auto_resolve_trigger_types" => %w[owner_approved],
              "weights" => { "unified_failure_pressure" => 0.6 },
              "interruption_cost" => { "base" => 0.2 }
            )
          end,
          strategy: "escalation_refinement",
          reasoning: "Lower threshold where humans historically help",
          expected_improvement: "Faster handoff on genuinely blocked PRs",
          diff: [ { "path" => "/escalation/human_value_threshold", "from" => 0.65, "to" => 0.45 } ],
          provenance: {}
        )
      end
      let(:escalation_candidate) do
        described_class.call(
          policy_snapshot: {
            id: escalation_policy.id,
            policy_type: "escalation",
            policy_key: escalation_policy.policy_key,
            name: escalation_policy.name,
            version_id: escalation_policy.current_version.id,
            version: escalation_policy.current_version.version,
            configuration: escalation_mutation.configuration
          },
          account: account,
          mutations: [ escalation_mutation ]
        ).first
      end

      it "persists escalation candidates using escalation-specific rule and parameter keys" do
        expect(escalation_candidate.rules).to include(
          "explicit_triggers" => %w[operational_failure_breaker],
          "auto_resolve_trigger_types" => %w[owner_approved]
        )
        expect(escalation_candidate.parameters).to include(
          "human_value_threshold" => 0.45,
          "weights" => { "unified_failure_pressure" => 0.6 }
        )
      end
    end
  end
end
