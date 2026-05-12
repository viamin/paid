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
  end
end
