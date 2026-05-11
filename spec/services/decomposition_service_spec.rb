# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecompositionService, :no_db do
  let(:project) { Struct.new(:id, :account, keyword_init: true).new(id: 7, account: account) }
  let(:account) { Struct.new(:id, keyword_init: true).new(id: 9) }
  let(:sub_components) { %w[database service\ layer api\ endpoints views] }
  let(:plan_result) do
    instance_double(
      DecompositionPlan::Generate::Result,
      tasks: [ { index: 0, title: "task", description: "desc", scope: "view", deps: [] } ],
      valid?: true,
      sorted_indices: [ 0 ],
      errors: [],
      task_count: 1
    )
  end

  before do
    allow(DecompositionPlan::Generate).to receive(:call).and_return(plan_result)
  end

  def build_service(components: sub_components, policy_override: nil)
    described_class.new(
      title: "Notifications",
      description: "Build notifications",
      sub_components: components,
      project: project,
      policy_override: policy_override
    )
  end

  def build_policy_version(id:, version:, rules:, parameters:)
    Struct.new(:id, :version, :rules, :parameters, keyword_init: true)
      .new(id:, version:, rules:, parameters:)
  end

  def build_policy(id:, version:)
    Struct.new(:id, :policy_key, :current_version, keyword_init: true)
      .new(id:, policy_key: described_class::POLICY_KEY, current_version: version)
  end

  def build_coordination_policy(id:, version:, rules:, parameters:)
    build_policy(
      id: id,
      version: build_policy_version(id: version[:id], version: version[:number], rules:, parameters:)
    )
  end

  def build_nested_coordination_policy
    build_coordination_policy(
      id: 6,
      version: { id: 12, number: 1 },
      rules: { "decomposition" => { "enabled" => true, "min_components_to_decompose" => 3 } },
      parameters: { "decomposition" => { "max_tasks" => 2, "layer_order" => %w[view controller] } }
    )
  end

  it "preserves the legacy coordination namespace as a compatibility wrapper" do
    expect(Coordination::DecompositionService < described_class).to be(true)
  end

  it "uses a coordination policy before strategy defaults" do
    policy = build_coordination_policy(
      id: 5,
      version: { id: 11, number: 3 },
      rules: { "enabled" => true, "min_components_to_decompose" => 3 },
      parameters: { "max_tasks" => 2, "layer_order" => %w[view controller service model] }
    )

    service = build_service
    allow(service).to receive(:coordination_policy).and_return(policy)
    allow(OrchestrationStrategies::Resolve).to receive(:call)

    result = service.call

    expect(result.policy_source).to eq("coordination_policy")
    expect(result.policy_applied).to include(
      "coordination_policy_id" => 5,
      "coordination_policy_version_id" => 11,
      "coordination_policy_version" => 3
    )
    expect(DecompositionPlan::Generate).to have_received(:call).with(
      hash_including(max_tasks: 2, layer_order: %w[view controller service model])
    )
    expect(OrchestrationStrategies::Resolve).not_to have_received(:call)
  end

  it "falls back to strategy-backed rules when no coordination policy exists" do
    strategy = Struct.new(:configuration, keyword_init: true).new(
      configuration: {
        "decomposition" => {
          "min_components_to_decompose" => 5
        }
      }
    )

    service = build_service(components: %w[database models service\ layer])
    allow(service).to receive(:coordination_policy).and_return(nil)
    allow(OrchestrationStrategies::Resolve).to receive(:call)
      .with(strategy_type: described_class::STRATEGY_TYPE, account:)
      .and_return(strategy)

    result = service.call

    expect(result).to be_skipped
    expect(result.skip_reason).to eq("below_complexity_threshold")
    expect(result.policy_source).to eq("feature_orchestration")
  end

  it "treats default-shaped strategy decomposition config as defaults fallback" do
    strategy = Struct.new(:configuration, keyword_init: true).new(
      configuration: OrchestrationStrategies::Defaults.feature_orchestration
    )

    service = build_service(components: [ "database" ])
    allow(service).to receive(:coordination_policy).and_return(nil)
    allow(OrchestrationStrategies::Resolve).to receive(:call)
      .with(strategy_type: described_class::STRATEGY_TYPE, account:)
      .and_return(strategy)

    result = service.call

    expect(result).to be_skipped
    expect(result.skip_reason).to eq("below_complexity_threshold")
    expect(result.policy_source).to eq("defaults")
  end

  it "uses defaults when neither coordination policies nor strategies are available" do
    service = build_service(components: %w[database models service\ layer])
    allow(service).to receive(:coordination_policy).and_return(nil)
    allow(OrchestrationStrategies::Resolve).to receive(:call)
      .with(strategy_type: described_class::STRATEGY_TYPE, account:)
      .and_return(nil)

    result = service.call

    expect(result).to be_valid
    expect(result).not_to be_skipped
    expect(result.policy_source).to eq("defaults")
  end

  it "treats an explicit policy override as the highest-precedence source" do
    service = build_service(policy_override: {
      "decomposition" => {
        "enabled" => true,
        "max_tasks" => 1,
        "layer_order" => %w[view]
      }
    })
    allow(OrchestrationStrategies::Resolve).to receive(:call)

    result = service.call

    expect(result.policy_source).to eq("experiment")
    expect(result.task_count).to eq(1)
    expect(OrchestrationStrategies::Resolve).not_to have_received(:call)
  end

  it "supports nested coordination policy payloads" do
    service = build_service
    allow(service).to receive(:coordination_policy).and_return(build_nested_coordination_policy)

    result = service.call
    expected_layer_order = %w[view controller model service]

    expect(result.policy_source).to eq("coordination_policy")
    expect(result.policy_applied).to include(
      "max_tasks" => 2,
      "min_components_to_decompose" => 3,
      "layer_order" => expected_layer_order
    )
    expect(DecompositionPlan::Generate).to have_received(:call).with(
      hash_including(max_tasks: 2, layer_order: expected_layer_order)
    )
  end

  it "normalizes invalid coordination policy payloads into safe defaults" do
    policy_version = build_policy_version(id: 12, version: 1, rules: "invalid",
      parameters: {
        "enabled" => "nope",
        "max_tasks" => "invalid",
        "layer_order" => [ "view", "unknown" ]
      })
    policy = build_policy(id: 6, version: policy_version)

    service = build_service
    allow(service).to receive(:coordination_policy).and_return(policy)

    result = service.call

    expect(result.policy_source).to eq("coordination_policy")
    expect(result.policy_applied).to include(
      "enabled" => true,
      "max_tasks" => 20,
      "layer_order" => %w[view model service controller]
    )
    expect(DecompositionPlan::Generate).to have_received(:call).with(
      hash_including(max_tasks: 20, layer_order: %w[view model service controller])
    )
  end

  it "falls back safely when policy resolution raises" do
    service = build_service
    allow(service).to receive(:coordination_policy).and_raise(StandardError, "boom")

    result = service.call

    expect(result).to be_valid
    expect(result).not_to be_skipped
    expect(result.policy_source).to eq("fallback")
  end
end
