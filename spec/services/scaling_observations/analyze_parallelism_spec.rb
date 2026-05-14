# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingObservations::AnalyzeParallelism, :no_db do
  describe ".call" do
    it "detects diminishing returns and capacity thresholds, then recommends the best safe count" do
      observations = seed_recommendation_dataset

      result = described_class.call(observations:)

      expect_recommendation_result(result)
    end

    it "returns insufficient_data until enough samples exist for at least one value" do
      observations = seed_observations(2, durations: [ 220 ], costs: [ 180 ], observed_parallelism: 2)

      result = described_class.call(observations:, min_samples: 2)

      expect(result.status).to eq("insufficient_data")
      expect(result.recommended_agent_count).to be_nil
      expect(result.allocator_decision).to be_nil
      expect(result.values).to contain_exactly(
        hash_including(
          "parallelism" => 2,
          "sample_count" => 1,
          "success_rate" => 1.0
        )
      )
    end

    it "memoizes an empty recommendation across repeated calls" do
      observations = seed_observations(4,
        durations: [ 205, 200 ],
        costs: [ 340, 335 ],
        launched: [ 3, 3 ],
        blocked: [ 1, 1 ],
        observed_parallelism: 3)

      analyzer = described_class.new(observations:, min_samples: 2)

      expect(analyzer.send(:recommendation)).to be_nil
      expect(analyzer.send(:recommendation)).to be_nil
      expect(analyzer.call.status).to eq("collecting")
      expect(analyzer.call.allocator_decision).to be_nil
    end

    it "analyzes planned parallelism independently from total agent count" do
      observations = seed_parallelism_dataset

      result = described_class.call(observations:)

      expect_parallelism_specific_result(result)
    end
  end

  def seed_recommendation_dataset
    seed_observations(1, durations: [ 300, 290, 310 ], costs: [ 100, 95, 105 ]) +
      seed_observations(2, durations: [ 200, 190, 210 ], costs: [ 180, 175, 185 ], observed_parallelism: 2) +
      seed_observations(3, durations: [ 180, 178, 182 ], costs: [ 255, 250, 260 ], observed_parallelism: 3) +
      seed_observations(4,
      durations: [ 175, 178, 182 ],
      costs: [ 340, 335, 345 ],
      successes: [ true, false, false ],
      launched: [ 3, 3, 3 ],
      blocked: [ 1, 1, 1 ],
      observed_parallelism: 3)
  end

  def seed_parallelism_dataset
    seed_parallelism_observations(1, durations: [ 300, 295, 305 ], costs: [ 120, 118, 122 ]) +
      seed_parallelism_observations(2, durations: [ 200, 198, 202 ], costs: [ 125, 124, 126 ]) +
      seed_parallelism_observations(4,
      durations: [ 190, 195, 188 ],
      costs: [ 150, 152, 148 ],
      successes: [ true, false, false ],
      launched: [ 3, 3, 3 ],
      blocked: [ 1, 1, 1 ],
      observed_parallelism: 3)
  end

  def expect_recommendation_result(result)
    expect(result.status).to eq("ready")
    expect(result.sample_count).to eq(12)
    expect(result.diminishing_returns_at).to eq(3)
    expect(result.threshold_signal_at).to eq(4)
    expect(result.recommended_agent_count).to eq(2)
    expect(result.recommended_max_batch_size).to eq(2)
    expect(result.allocator_decision).to include(
      "requested_agent_count" => 2,
      "max_batch_size" => 2,
      "sample_count" => 3,
      "reason" => "best_success_rate_before_threshold"
    )
    expect(result.values).to include(
      hash_including(
        "parallelism" => 3,
        "signals" => include("diminishing_returns")
      ),
      hash_including(
        "parallelism" => 4,
        "signals" => include("success_rate_regression", "blocked_capacity", "launch_shortfall")
      )
    )
  end

  def expect_parallelism_specific_result(result)
    expect(result.status).to eq("ready")
    expect(result.recommended_parallelism).to eq(2)
    expect(result.recommended_agent_count).to eq(4)
    expect(result.recommended_max_batch_size).to eq(2)
    expect(result.diminishing_returns_at).to eq(4)
    expect(result.threshold_signal_at).to eq(4)
    expect(result.values).to include(
      hash_including(
        "parallelism" => 1,
        "recommended_agent_count" => 4,
        "avg_agent_count_planned" => 4.0
      ),
      hash_including(
        "parallelism" => 4,
        "signals" => include("success_rate_regression")
      )
    )
    expect(result.allocator_decision).to include(
      "requested_agent_count" => 4,
      "parallelism" => 2,
      "max_batch_size" => 2,
      "sample_count" => 3
    )
  end

  def seed_observations(agent_count, durations:, costs:, successes: nil, launched: nil, blocked: nil, observed_parallelism: nil)
    durations.each_with_index.map do |duration, index|
      success = value_at(successes, index, true)
      launched_count = value_at(launched, index, agent_count)
      blocked_count = value_at(blocked, index, 0)

      build_observation(
        workflow_id: "wf-#{agent_count}-#{index}",
        agent_count_planned: agent_count,
        agent_count_launched: launched_count,
        agent_count_succeeded: success ? launched_count : 0,
        agent_count_failed: success ? 0 : launched_count,
        agent_count_blocked: blocked_count,
        parallelism_planned: agent_count,
        parallelism_observed: observed_parallelism || agent_count,
        success: success,
        duration_seconds: duration,
        total_cost_cents: costs.fetch(index))
    end
  end

  def seed_parallelism_observations(parallelism, durations:, costs:, successes: nil, launched: nil, blocked: nil, observed_parallelism: nil)
    durations.each_with_index.map do |duration, index|
      success = value_at(successes, index, true)
      launched_count = value_at(launched, index, 4)
      blocked_count = value_at(blocked, index, 0)

      build_observation(
        workflow_id: "wf-parallelism-#{parallelism}-#{index}",
        agent_count_planned: 4,
        agent_count_launched: launched_count,
        agent_count_succeeded: success ? launched_count : 0,
        agent_count_failed: success ? 0 : launched_count,
        agent_count_blocked: blocked_count,
        parallelism_planned: parallelism,
        parallelism_observed: observed_parallelism || parallelism,
        success: success,
        duration_seconds: duration,
        total_cost_cents: costs.fetch(index))
    end
  end

  def value_at(values, index, default)
    return default unless values

    values.fetch(index, default)
  end

  def build_observation(**attributes)
    observation_class.new(**{
      workflow_name: "FeatureOrchestrationWorkflow",
      observation_type: "feature_orchestration",
      status: "completed",
      success: true,
      parallel_execution: true,
      task_count: 4,
      dependency_edge_count: 1,
      parallelizable_group_count: 1,
      agent_count_planned: 2,
      agent_count_launched: 2,
      agent_count_succeeded: 2,
      agent_count_failed: 0,
      agent_count_blocked: 0,
      total_iterations: 3,
      max_iterations: 2,
      parallelism_planned: 2,
      parallelism_observed: 2,
      batch_count: 1,
      duration_seconds: 120,
      total_cost_cents: 100,
      total_input_tokens: 0,
      total_output_tokens: 0,
      metadata: {}
    }.merge(attributes))
  end

  def observation_class
    Struct.new(
      :workflow_id,
      :workflow_name,
      :observation_type,
      :status,
      :success,
      :parallel_execution,
      :task_count,
      :dependency_edge_count,
      :parallelizable_group_count,
      :agent_count_planned,
      :agent_count_launched,
      :agent_count_succeeded,
      :agent_count_failed,
      :agent_count_blocked,
      :total_iterations,
      :max_iterations,
      :parallelism_planned,
      :parallelism_observed,
      :batch_count,
      :duration_seconds,
      :total_cost_cents,
      :total_input_tokens,
      :total_output_tokens,
      :metadata,
      keyword_init: true
    )
  end
end
