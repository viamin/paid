# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::GenerateCoordinationPolicyCandidatesActivity, :no_db do
  let(:activity) { described_class.new }
  let(:connection_pool) { instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool, active_connection?: false) }
  let(:policy) do
    {
      id: 3,
      policy_type: "decomposition",
      policy_key: "feature_decomposition",
      name: "Feature Decomposition",
      version: 2,
      account_id: 9,
      configuration: OrchestrationStrategies::Defaults.feature_orchestration
    }
  end
  let(:mutation) do
    StrategyEvolution::Mutate::Mutation.new(
      configuration: policy[:configuration],
      strategy: "refinement",
      reasoning: "Tune decomposition thresholds",
      expected_improvement: "Higher planning success rate",
      diff: [ { "path" => "/decomposition/max_tasks", "from" => 20, "to" => 12 } ],
      provenance: { "source_version" => 2 }
    )
  end

  before do
    allow(TenantContext).to receive(:with_system_access).and_yield
    allow(TenantContext).to receive(:with).and_yield
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
  end

  it "serializes generated policy mutations" do
    allow(CoordinationPolicyEvolution::GenerateCandidates).to receive(:call).and_return([ mutation ])

    result = activity.execute(
      policy: policy,
      performance: { decision_count: 12 },
      sample_successes: [],
      sample_failures: [],
      mutation_count: 1
    )

    expect(result[:policy_type]).to eq("decomposition")
    expect(result[:mutations]).to contain_exactly(
      include(strategy: "refinement", expected_improvement: "Higher planning success rate")
    )
  end
end
