# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyEvolution::Mutate do
  let(:strategy) do
    {
      id: 12,
      strategy_type: "review_settings",
      name: "Review Settings",
      version: 3,
      account_id: 7,
      configuration: OrchestrationStrategies::Defaults.review_settings
    }
  end
  let(:analysis) do
    {
      prior_versions: [ strategy.except(:configuration).merge(configuration: strategy[:configuration]) ],
      performance: { decision_count: 12, success_rate: 0.42, guardrail_violation_types: { "loop_detected" => 2 } },
      sample_successes: [ { id: 1, run_status: "completed" } ],
      sample_failures: [ { id: 2, run_status: "paused", guardrail_violation_type: "loop_detected" } ]
    }
  end
  let(:candidate_config) do
    strategy[:configuration].deep_dup.tap do |config|
      config["methods"]["paid_agent"]["termination"]["timeout_minutes"] = 20
    end
  end
  let(:valid_response) do
    JSON.generate(
      "mutations" => [
        {
          "configuration" => candidate_config,
          "strategy" => "risk_reduction",
          "reasoning" => "Shorten review retries when loops appear",
          "expected_improvement" => "Fewer paused review runs"
        }
      ]
    )
  end
  let(:response) { instance_double(AgentHarness::Response, success?: true, output: valid_response) }

  before do
    allow(AgentHarness).to receive(:send_message).and_return(response)
    allow(Llm::TextMode).to receive(:options).and_return({})
  end

  it "returns structured mutations with provenance and diffs" do
    mutations = described_class.call(strategy: strategy, analysis: analysis, options: { mutation_count: 1 })

    expect(mutations.size).to eq(1)
    expect(mutations.first.strategy).to eq("risk_reduction")
    expect(mutations.first.configuration.dig("methods", "paid_agent", "termination", "timeout_minutes")).to eq(20)
    expect(mutations.first.diff).to contain_exactly(
      include("path" => "/methods/paid_agent/termination/timeout_minutes", "from" => 30, "to" => 20)
    )
    expect(mutations.first.provenance).to include(
      "source_strategy_id" => 12,
      "source_version" => 3
    )
  end

  it "passes historical analysis into the LLM prompt" do
    described_class.call(strategy: strategy, analysis: analysis)

    expect(AgentHarness).to have_received(:send_message).with(
      a_string_including("\"decision_count\": 12", "\"loop_detected\": 2"),
      hash_including(provider: :claude, model: "claude-sonnet-4-6", timeout: 60, tools: :none)
    )
  end

  it "drops candidates that violate the current strategy schema guardrail" do
    invalid_response = JSON.generate(
      "mutations" => [
        {
          "configuration" => candidate_config.merge("unexpected" => true),
          "strategy" => "risk_reduction",
          "reasoning" => "invalid",
          "expected_improvement" => "invalid"
        }
      ]
    )
    allow(response).to receive(:output).and_return(invalid_response)

    expect(described_class.call(strategy: strategy, analysis: analysis)).to eq([])
  end

  context "with array-bearing strategy types" do
    let(:strategy) do
      {
        id: 20,
        strategy_type: "feature_orchestration",
        name: "Feature Orchestration",
        version: 1,
        account_id: 7,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration
      }
    end
    let(:candidate_config) do
      strategy[:configuration].deep_dup.tap do |config|
        config["planning_phases"] = %w[fetch_planning_context decompose_feature]
      end
    end

    it "accepts candidates whose arrays contain valid element types" do
      mutations = described_class.call(strategy: strategy, analysis: analysis, options: { mutation_count: 1 })

      expect(mutations.size).to eq(1)
    end

    it "rejects candidates whose arrays contain invalid element types" do
      bad_config = strategy[:configuration].deep_dup.tap do |config|
        config["planning_phases"] = [ 1, { "oops" => true } ]
      end
      bad_response = JSON.generate(
        "mutations" => [
          {
            "configuration" => bad_config,
            "strategy" => "risk_reduction",
            "reasoning" => "invalid array elements",
            "expected_improvement" => "nothing"
          }
        ]
      )
      allow(response).to receive(:output).and_return(bad_response)

      expect(described_class.call(strategy: strategy, analysis: analysis)).to eq([])
    end
  end
end
