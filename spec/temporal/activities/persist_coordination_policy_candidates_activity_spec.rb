# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::PersistCoordinationPolicyCandidatesActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:policy) do
    create(:coordination_policy, :active,
      account: account,
      policy_type: "decomposition",
      policy_key: "feature_decomposition",
      name: "Feature Decomposition").tap do |record|
        record.current_version.update!(
          version: 2,
          rules: { "enabled" => true, "min_components_to_decompose" => 2 },
          parameters: { "max_tasks" => 20, "layer_order" => %w[view model service controller] }
        )
      end
  end
  let(:input) do
    {
      account_id: account.id,
      policy: {
        id: policy.id,
        policy_type: policy.policy_type,
        policy_key: policy.policy_key,
        name: policy.name,
        version_id: policy.current_version.id,
        version: policy.current_version.version,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration
      },
      mutations: [
        {
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup.tap do |config|
            config["decomposition"] = {
              "enabled" => true,
              "min_components_to_decompose" => 2,
              "max_tasks" => 12,
              "layer_order" => %w[view controller service model]
            }
          end,
          strategy: "observability",
          reasoning: "Record more context",
          expected_improvement: "Faster diagnosis",
          diff: [ { "path" => "/decomposition/max_tasks", "from" => 20, "to" => 12 } ],
          provenance: { "source_version" => policy.current_version.version }
        }
      ]
    }
  end

  it "rehydrates mutations with the canonical mutation type" do
    allow(CoordinationPolicyEvolution::CreateCandidates).to receive(:call).and_return([])

    activity.execute(input)

    expect(CoordinationPolicyEvolution::CreateCandidates).to have_received(:call) do |kwargs|
      expect(kwargs[:mutations]).to all(be_a(StrategyEvolution::Mutate::Mutation))
    end
  end

  it "persists draft policy candidates and returns their ids" do
    result = activity.execute(input)

    expect(result[:policy_type]).to eq("decomposition")
    expect(result[:candidate_count]).to eq(1)
    expect(result[:candidate_ids]).not_to be_empty
    expect(CoordinationPolicyVersion.find(result[:candidate_ids].first).status).to eq("draft")
  end
end
