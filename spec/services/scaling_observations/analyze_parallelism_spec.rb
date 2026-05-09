# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingObservations::AnalyzeParallelism do
  describe ".call" do
    let(:project) { create(:project) }

    it "detects diminishing returns and capacity thresholds, then recommends the best safe count" do
      seed_recommendation_dataset(project)

      result = described_class.call(observations: ScalingObservation.where(project: project))

      expect_recommendation_result(result)
    end

    it "returns insufficient_data until enough samples exist for at least one value" do
      seed_observations(project, 2, durations: [ 220 ], costs: [ 180 ], observed_parallelism: 2)

      result = described_class.call(observations: ScalingObservation.where(project: project), min_samples: 2)

      expect(result.status).to eq("insufficient_data")
      expect(result.recommended_agent_count).to be_nil
      expect(result.allocator_decision).to be_nil
      expect(result.values).to contain_exactly(
        hash_including(
          "agent_count" => 2,
          "sample_count" => 1,
          "success_rate" => 1.0
        )
      )
    end
  end

  def seed_recommendation_dataset(project)
    seed_observations(project, 1, durations: [ 300, 290, 310 ], costs: [ 100, 95, 105 ])
    seed_observations(project, 2, durations: [ 200, 190, 210 ], costs: [ 180, 175, 185 ], observed_parallelism: 2)
    seed_observations(project, 3, durations: [ 180, 178, 182 ], costs: [ 255, 250, 260 ], observed_parallelism: 3)
    seed_observations(project, 4,
      durations: [ 175, 178, 182 ],
      costs: [ 340, 335, 345 ],
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
      "reason" => "best_success_rate_before_threshold"
    )
    expect(result.values).to include(
      hash_including(
        "agent_count" => 3,
        "signals" => include("diminishing_returns")
      ),
      hash_including(
        "agent_count" => 4,
        "signals" => include("success_rate_regression", "blocked_capacity", "launch_shortfall")
      )
    )
  end

  def seed_observations(project, agent_count, durations:, costs:, successes: nil, launched: nil, blocked: nil, observed_parallelism: nil)
    durations.each_with_index do |duration, index|
      success = value_at(successes, index, true)
      launched_count = value_at(launched, index, agent_count)
      blocked_count = value_at(blocked, index, 0)

      create(:scaling_observation,
        project: project,
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

  def value_at(values, index, default)
    return default unless values

    values.fetch(index, default)
  end
end
